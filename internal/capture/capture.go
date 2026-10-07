// Package capture records MIDI messages in the format web/jog/replay.js reads:
// a JSON array of {t, d, port}, t in milliseconds, d the raw bytes.
//
// That is the same shape calibrate.html writes per step, so a capture taken
// natively here replays through the browser lab (demo.html "replay capture")
// and feeds analyze-capture.mjs's flattenCapture without conversion.
package capture

import (
	"encoding/json"
	"io"
	"slices"
	"sync"
	"time"
)

// Msg is one MIDI message. D is []int, not []byte, so it marshals as a JSON
// array of numbers rather than base64.
type Msg struct {
	T    float64 `json:"t"`
	D    []int   `json:"d"`
	Port string  `json:"port"`
}

// Recorder accumulates messages; safe for use from MIDI driver callbacks.
type Recorder struct {
	mu    sync.Mutex
	start time.Time
	msgs  []Msg
}

func NewRecorder(start time.Time) *Recorder { return &Recorder{start: start} }

// Add records b as received on port at time at.
func (r *Recorder) Add(port string, b []byte, at time.Time) Msg {
	d := make([]int, len(b))
	for i, v := range b {
		d[i] = int(v)
	}
	m := Msg{T: float64(at.Sub(r.start).Microseconds()) / 1000, D: d, Port: port}
	r.mu.Lock()
	r.msgs = append(r.msgs, m)
	r.mu.Unlock()
	return m
}

func (r *Recorder) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.msgs)
}

// WriteJSON writes the capture as a bare array (replay.js accepts either a
// bare array or a calibrate.html session).
func (r *Recorder) WriteJSON(w io.Writer) error {
	r.mu.Lock()
	msgs := slices.Clone(r.msgs)
	r.mu.Unlock()
	if msgs == nil {
		msgs = []Msg{}
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", " ")
	return enc.Encode(msgs)
}
