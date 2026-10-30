"""Exercise the real webhook body as a Go text/template, without credentials."""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "manifest/envs/dev/resources/regalia-preview-secretstore.yaml"
KEYS = (
    "regalia-preview-github-app-id",
    "regalia-preview-github-app-installation-id",
    "regalia-preview-github-app-private-key",
)


@unittest.skipUnless(shutil.which("go") and subprocess.run(
    ["go", "list", "bytes"], capture_output=True).returncode == 0,
    "working Go stdlib unavailable")
class PreviewSecretStoreTests(unittest.TestCase):
    def test_only_three_keys_in_actual_namespace_can_render_request(self):
        store = yaml.safe_load(STORE.read_text())
        self.assertEqual(store["spec"]["conditions"],
                         [{"namespaces": ["regalia-preview-control"]}])
        body = store["spec"]["provider"]["webhook"]["body"]
        self.assertEqual(store["spec"]["provider"]["webhook"]["method"], "POST")
        cases = [
            ("regalia-preview-control", key, True) for key in KEYS
        ] + [
            ("regalia-preview-control", "some-other-vault-key", False),
            ("regalia-preview-control", KEYS[0] + "-other", False),
            ("argocd", KEYS[0], False),
            ("", KEYS[0], False),  # PushSecret has no remoteRef.namespace.
        ]
        # The mock functions implement the two Sprig functions used by the
        # installed ESO webhook. Everything else uses Go's text/template.
        source = r'''package main
import ("bytes"; "encoding/json"; "errors"; "fmt"; "text/template")
func main() {
  t := template.Must(template.New("body").Funcs(template.FuncMap{
    "fail": func(s string) (string,error) { return "",errors.New(s) },
    "toJson": func(s string) string { b,_:=json.Marshal(s); return string(b) },
  }).Parse(BODY))
  for _, c := range CASES {
    var out bytes.Buffer
    err := t.Execute(&out,map[string]any{"remoteRef":map[string]string{"namespace":c.NS,"key":c.Key}})
    if c.Allowed {
      if err != nil { panic(err) }
      var doc struct { Secret struct { Name string } }
      if err:=json.Unmarshal(out.Bytes(),&doc); err!=nil { panic(err) }
      if doc.Secret.Name != c.Key { panic(fmt.Sprintf("wrong key %q",doc.Secret.Name)) }
    } else if err == nil { panic(fmt.Sprintf("accepted ns=%q key=%q",c.NS,c.Key)) }
  }
}
type Case struct { NS,Key string; Allowed bool }
'''
        literal_cases = ",".join(
            f"{{{json.dumps(ns)},{json.dumps(key)},{str(allowed).lower()}}}"
            for ns, key, allowed in cases)
        source = source.replace("BODY", json.dumps(body)).replace(
            "CASES", "[]Case{" + literal_cases + "}")
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "main.go"
            script.write_text(source)
            result = subprocess.run(["go", "run", str(script)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
