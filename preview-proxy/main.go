package main

import (
 "fmt"
 "log"
 "net/http"
 "net/http/httputil"
 "net/url"
 "os"
 "strings"
 "time"
)

var appCookies = map[string]bool{
 "regalia-user-session": true, "admin-session": true,
 "signup-session": true, "oauth2-session": true,
 "admin-oauth2-session": true,
}

var requestHeaders = []string{"Accept", "Accept-Encoding", "Accept-Language", "Content-Type", "Origin", "Referer", "User-Agent", "If-None-Match", "If-Modified-Since", "Range"}

type proxy struct {
 host string
 authURL string
 authClient *http.Client
 frontend, backend *httputil.ReverseProxy
}

func newProxy(host, authURL, frontendURL, backendURL string) (*proxy, error) {
 if host == "" || strings.ContainsAny(host, "/:@") { return nil, fmt.Errorf("invalid preview host") }
 front, err := url.Parse(frontendURL); if err != nil { return nil, err }
 back, err := url.Parse(backendURL); if err != nil { return nil, err }
 if front.Scheme != "http" || back.Scheme != "http" { return nil, fmt.Errorf("upstreams must use cluster HTTP") }
 p := &proxy{host:host, authURL:authURL,
  authClient:&http.Client{Timeout:5*time.Second, CheckRedirect:func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
  frontend:httputil.NewSingleHostReverseProxy(front), backend:httputil.NewSingleHostReverseProxy(back)}
 for _, rp := range []*httputil.ReverseProxy{p.frontend,p.backend} {
  rp.ModifyResponse = filterResponse
  rp.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) { log.Printf("upstream: %v",err); http.Error(w,"upstream unavailable",http.StatusBadGateway) }
 }
 return p,nil
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
 if r.Host != p.host { http.Error(w,"invalid host",http.StatusMisdirectedRequest); return }
 authReq, err := http.NewRequestWithContext(r.Context(),http.MethodGet,p.authURL,nil)
 if err != nil { http.Error(w,"auth unavailable",http.StatusServiceUnavailable); return }
 authReq.Header.Set("Cookie",r.Header.Get("Cookie"))
 authReq.Header.Set("X-Forwarded-Proto","https")
 authReq.Header.Set("X-Forwarded-Host",p.host)
 authResp, err := p.authClient.Do(authReq)
 if err != nil { http.Error(w,"auth unavailable",http.StatusServiceUnavailable); return }
 authResp.Body.Close()
 if authResp.StatusCode != http.StatusAccepted && authResp.StatusCode != http.StatusOK {
  if authResp.StatusCode == http.StatusUnauthorized || authResp.StatusCode == http.StatusForbidden {
   dest := "https://"+p.host+r.URL.RequestURI()
   http.Redirect(w,r,"https://contest.k8s-dev.ictsc.net/oauth2/start?rd="+url.QueryEscape(dest),http.StatusFound)
   return
  }
  http.Error(w,"auth unavailable",http.StatusServiceUnavailable); return
 }
 clean := r.Clone(r.Context())
 clean.Header = make(http.Header)
 for _, name := range requestHeaders { if values,ok := r.Header[http.CanonicalHeaderKey(name)]; ok { for _,v := range values {clean.Header.Add(name,v)} } }
 for _, c := range r.Cookies() { if appCookies[c.Name] { clean.AddCookie(&http.Cookie{Name:c.Name, Value:c.Value}) } }
 clean.Header.Del("Authorization")
 clean.Header.Del("Proxy-Authorization")
 clean.Header.Del("X-Auth-Request-User")
 clean.Header.Del("X-Auth-Request-Email")
 clean.Header.Del("X-Forwarded-User")
 clean.Header.Del("X-Forwarded-Email")
 // Avoid forwarding browser cookies or identity headers to PR-controlled code.
 if strings.HasPrefix(r.URL.Path,"/api/") || r.URL.Path == "/api" {p.backend.ServeHTTP(w,clean)} else {p.frontend.ServeHTTP(w,clean)}
}

func filterResponse(resp *http.Response) error {
 cookies := resp.Cookies()
 resp.Header.Del("Set-Cookie")
 resp.Header.Del("Clear-Site-Data")
 resp.Header.Del("Access-Control-Allow-Credentials")
 for _, c := range cookies {
  if !appCookies[c.Name] { continue }
  safe := &http.Cookie{Name:c.Name,Value:c.Value,Path:"/",Secure:true,HttpOnly:true,SameSite:http.SameSiteStrictMode,MaxAge:c.MaxAge}
  if c.Expires.IsZero() == false { safe.Expires = c.Expires }
  resp.Header.Add("Set-Cookie",safe.String())
 }
 return nil
}

func main() {
 host := os.Getenv("PREVIEW_HOST")
 auth := os.Getenv("AUTH_URL")
 if auth == "" { auth = "http://regalia-auth.oauth2-proxy.svc.cluster.local/oauth2/auth" }
 p, err := newProxy(host,auth,"http://preview-frontend:8080","http://preview-backend:8080")
 if err != nil { log.Fatal(err) }
 srv := &http.Server{Addr:":8080",Handler:p,ReadHeaderTimeout:5*time.Second}
 log.Fatal(srv.ListenAndServe())
}
