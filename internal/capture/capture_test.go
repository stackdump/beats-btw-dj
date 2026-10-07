package capture

import (
	"bytes"
	"encoding/json"
	"testing"
	"time"
)

func TestWriteJSONMatchesReplayShape(t *testing.T) {
	start := time.Unix(0, 0)
	r := NewRecorder(start)
	r.Add("DJControl Inpulse 200 MK3", []byte{0xB1, 0x0A, 0x01}, start.Add(1500*time.Microsecond))
	r.Add("DJControl Inpulse 200 MK3", []byte{0x91, 0x08, 0x7F}, start.Add(3*time.Millisecond))

	var buf bytes.Buffer
	if err := r.WriteJSON(&buf); err != nil {
		t.Fatal(err)
	}
	// replay.js flattenCapture keeps entries where Array.isArray(m.d) && typeof m.t === 'number'.
	var got []map[string]any
	if err := json.Unmarshal(buf.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0]["t"].(float64) != 1.5 {
		t.Errorf("t = %v, want 1.5", got[0]["t"])
	}
	d, ok := got[1]["d"].([]any)
	if !ok || len(d) != 3 || d[0].(float64) != 0x91 {
		t.Errorf("d = %#v, want [145 8 127] as numbers", got[1]["d"])
	}
}

func TestEmptyCaptureIsArray(t *testing.T) {
	var buf bytes.Buffer
	if err := NewRecorder(time.Now()).WriteJSON(&buf); err != nil {
		t.Fatal(err)
	}
	if s := bytes.TrimSpace(buf.Bytes()); string(s) != "[]" {
		t.Errorf("empty capture = %s, want []", s)
	}
}
