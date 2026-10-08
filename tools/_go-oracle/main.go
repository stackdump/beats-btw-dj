// Command go-oracle (directory is _-prefixed so `go test ./...` here skips it) is the Go half of dj-vevr-se's second oracle (ROADMAP 2.7).
//
// It does NOT build inside this repo: it imports beats-bitwrap-io/internal/generator,
// which Go only allows from inside that module's tree. scripts/beats-go-oracle.mjs
// copies this file into a temporary directory under the beats checkout, runs it,
// and removes it again.
//
//	stdin:  [{"id": "...", "genre": "techno", "overrides": {...}}, ...]
//	stdout: [{"id": "...", "bytes": N, "cid": "<hex sha256>", "name": "..."}, ...]
//
// "cid" is pflow.Project.CID(): the sha256 of the canonical model JSON, the same
// quantity as the JS canonicalProjectJSON hash.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	"beats-bitwrap-io/internal/generator"
)

type input struct {
	ID        string                 `json:"id"`
	Genre     string                 `json:"genre"`
	Overrides map[string]interface{} `json:"overrides"`
}

type output struct {
	ID    string `json:"id"`
	Bytes int    `json:"bytes"`
	CID   string `json:"cid"`
	Name  string `json:"name"`
	Nets  int    `json:"nets"`
	// PerNet is the sha256 of each net's canonical JSON (re-marshalled from the
	// canonical project, so keys are sorted and Go's HTML escaping applies).
	PerNet map[string]string `json:"perNet"`
}

func main() {
	var in []input
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		fmt.Fprintln(os.Stderr, "decode:", err)
		os.Exit(1)
	}
	out := make([]output, 0, len(in))
	for _, c := range in {
		if c.Overrides == nil {
			c.Overrides = map[string]interface{}{}
		}
		proj := generator.Compose(c.Genre, c.Overrides)
		canon, err := proj.CanonicalJSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: canonicalize: %v\n", c.ID, err)
			os.Exit(1)
		}
		var doc struct {
			Nets map[string]json.RawMessage `json:"nets"`
		}
		if err := json.Unmarshal(canon, &doc); err != nil {
			fmt.Fprintf(os.Stderr, "%s: reparse: %v\n", c.ID, err)
			os.Exit(1)
		}
		per := make(map[string]string, len(doc.Nets))
		for id, raw := range doc.Nets {
			var v interface{}
			if err := json.Unmarshal(raw, &v); err != nil {
				fmt.Fprintf(os.Stderr, "%s: net %s: %v\n", c.ID, id, err)
				os.Exit(1)
			}
			b, _ := json.Marshal(v)
			h := sha256.Sum256(b)
			per[id] = hex.EncodeToString(h[:])
		}
		out = append(out, output{ID: c.ID, Bytes: len(canon), CID: proj.CID(), Name: proj.Name, Nets: len(proj.Nets), PerNet: per})
	}
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, "encode:", err)
		os.Exit(1)
	}
}
