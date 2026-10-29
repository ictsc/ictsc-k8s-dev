package main

import (
 "net/http"
 "net/http/httptest"
 "strings"
 "testing"
)

func TestSanitizesHeadersAndCookies(t *testing.T) {
 auth := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  if !strings.Contains(r.Header.Get("Cookie"),"_regalia_preview=secret") { t.Error("auth cookie missing") }
  w.WriteHeader(http.StatusAccepted)
 }))
 defer auth.Close()
 backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  if got:=r.Header.Get("Authorization"); got!="" {t.Errorf("authorization leaked: %q",got)}
  if got:=r.Header.Get("X-Auth-Request-Email"); got!="" {t.Errorf("identity leaked: %q",got)}
  if got:=r.Header.Get("Cookie"); got!="regalia-user-session=app" {t.Errorf("cookie leak: %q",got)}
  w.Header().Add("Set-Cookie","_regalia_preview=poison; Domain=.k8s-dev.ictsc.net; Path=/")
  w.Header().Add("Set-Cookie","regalia-user-session=new; Domain=.k8s-dev.ictsc.net; Path=/")
  w.Header().Set("Clear-Site-Data","\"cookies\"")
  w.WriteHeader(http.StatusOK)
 }))
 defer backend.Close()
 p,err:=newProxy("pr-7.k8s-dev.ictsc.net",auth.URL,backend.URL,backend.URL)
 if err!=nil {t.Fatal(err)}
 req:=httptest.NewRequest("GET","https://pr-7.k8s-dev.ictsc.net/api/v1/health",nil)
 req.Header.Set("Cookie","_regalia_preview=secret; regalia-user-session=app; irrelevant=other")
 req.Header.Set("Authorization","Bearer sensitive")
 req.Header.Set("X-Auth-Request-Email","private@example.com")
 w:=httptest.NewRecorder(); p.ServeHTTP(w,req)
 if w.Code!=http.StatusOK {t.Fatalf("status %d",w.Code)}
 if w.Header().Get("Clear-Site-Data")!="" {t.Fatal("clear-site-data leak")}
 cookies:=w.Result().Cookies()
 if len(cookies)!=1 || cookies[0].Name!="regalia-user-session" || cookies[0].Domain!="" || !cookies[0].Secure || !cookies[0].HttpOnly {t.Fatalf("unsafe cookies: %+v",cookies)}
}

func TestUnauthorizedRedirectUsesFixedCallbackHost(t *testing.T) {
 auth:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){w.WriteHeader(http.StatusUnauthorized)}));defer auth.Close()
 app:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){t.Fatal("app called") }));defer app.Close()
 p,_:=newProxy("pr-7.k8s-dev.ictsc.net",auth.URL,app.URL,app.URL)
 req:=httptest.NewRequest("GET","https://pr-7.k8s-dev.ictsc.net/admin/",nil)
 w:=httptest.NewRecorder();p.ServeHTTP(w,req)
 if w.Code!=http.StatusFound {t.Fatalf("status %d",w.Code)}
 if !strings.HasPrefix(w.Header().Get("Location"),"https://contest.k8s-dev.ictsc.net/oauth2/start?rd=") {t.Fatal(w.Header().Get("Location"))}
}

func TestAuthFailureClosedAndHostCheck(t *testing.T) {
 auth:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){w.WriteHeader(http.StatusInternalServerError)}));defer auth.Close()
 app:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){t.Fatal("app called") }));defer app.Close()
 p,_:=newProxy("pr-7.k8s-dev.ictsc.net",auth.URL,app.URL,app.URL)
 req:=httptest.NewRequest("GET","https://pr-7.k8s-dev.ictsc.net/",nil)
 w:=httptest.NewRecorder();p.ServeHTTP(w,req)
 if w.Code!=http.StatusServiceUnavailable {t.Fatalf("status %d",w.Code)}
 req.Host="evil.example.com"
 w=httptest.NewRecorder();p.ServeHTTP(w,req)
 if w.Code!=http.StatusMisdirectedRequest {t.Fatalf("status %d",w.Code)}
}

func TestNoPublicHealthBypass(t *testing.T) {
 auth:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){w.WriteHeader(http.StatusUnauthorized)}));defer auth.Close()
 app:=httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter,_ *http.Request){t.Fatal("app called") }));defer app.Close()
 p,_:=newProxy("pr-7.k8s-dev.ictsc.net",auth.URL,app.URL,app.URL)
 req:=httptest.NewRequest("GET","https://pr-7.k8s-dev.ictsc.net/internal/healthz",nil)
 w:=httptest.NewRecorder();p.ServeHTTP(w,req)
 if w.Code!=http.StatusFound {t.Fatalf("status %d",w.Code)}
}
