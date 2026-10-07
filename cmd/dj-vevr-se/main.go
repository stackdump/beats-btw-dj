// dj-vevr-se: native (non-browser) MIDI tooling for DJ controllers.
//
//	dj-vevr-se ports                    list MIDI inputs and outputs
//	dj-vevr-se monitor [match]          print incoming messages live
//	dj-vevr-se capture -o f.json [match]  record until Ctrl-C, replayable in web/jog
//
// match is a case-insensitive substring of the input port name; empty means
// every input.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"time"

	"gitlab.com/gomidi/midi/v2"
	_ "gitlab.com/gomidi/midi/v2/drivers/rtmididrv"

	"dj-vevr-se/internal/capture"
)

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	defer midi.CloseDriver()
	var err error
	switch os.Args[1] {
	case "ports":
		err = ports()
	case "monitor":
		err = listen(os.Args[2:], "")
	case "capture":
		fs := flag.NewFlagSet("capture", flag.ExitOnError)
		out := fs.String("o", "", "output file (required)")
		fs.Parse(os.Args[2:])
		if *out == "" {
			fmt.Fprintln(os.Stderr, "capture: -o is required")
			os.Exit(2)
		}
		err = listen(fs.Args(), *out)
	case "version":
		fmt.Println(version)
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "dj-vevr-se:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: dj-vevr-se ports | monitor [match] | capture -o file.json [match] | version")
	os.Exit(2)
}

func ports() error {
	fmt.Println("inputs:")
	for _, p := range midi.GetInPorts() {
		fmt.Printf("  %d  %s\n", p.Number(), p.String())
	}
	fmt.Println("outputs:")
	for _, p := range midi.GetOutPorts() {
		fmt.Printf("  %d  %s\n", p.Number(), p.String())
	}
	return nil
}

// listen opens every input whose name contains match, prints each message,
// and on Ctrl-C writes the capture to out (if set).
func listen(args []string, out string) error {
	match := strings.ToLower(strings.Join(args, " "))
	start := time.Now()
	rec := capture.NewRecorder(start)

	var stops []func()
	for _, in := range midi.GetInPorts() {
		name := in.String()
		if match != "" && !strings.Contains(strings.ToLower(name), match) {
			continue
		}
		stop, err := midi.ListenTo(in, func(msg midi.Message, _ int32) {
			m := rec.Add(name, msg.Bytes(), time.Now())
			fmt.Printf("%10.3f  %-28s  % X  %s\n", m.T, trim(name, 28), msg.Bytes(), msg)
		}, midi.UseSysEx())
		if err != nil {
			return fmt.Errorf("open %q: %w", name, err)
		}
		fmt.Fprintf(os.Stderr, "listening: %s\n", name)
		stops = append(stops, stop)
	}
	if len(stops) == 0 {
		return fmt.Errorf("no MIDI input matches %q (try: dj-vevr-se ports)", match)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt)
	<-sig
	for _, stop := range stops {
		stop()
	}

	if out == "" {
		return nil
	}
	f, err := os.Create(out)
	if err != nil {
		return err
	}
	if err := rec.WriteJSON(f); err != nil {
		f.Close()
		return err
	}
	fmt.Fprintf(os.Stderr, "\nwrote %d messages to %s\n", rec.Len(), out)
	return f.Close()
}

func trim(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}
