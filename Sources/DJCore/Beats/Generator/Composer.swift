import Foundation

// Port of generator/composer.js: the orchestrator. Given a genre and the envelope's
// overrides (seed, structure, cohesion, ...), builds the same Project beats does.

/// `generateTrackName(genre, seed)`
public func generateTrackName(genre: String, seed: Double) -> String {
  let t = BeatsTables.shared
  var rng = Mulberry32(seed: Double(jsToInt32(seed)))
  let adj = t.adjectives[rng.nextInt(t.adjectives.count)]
  let noun = t.nouns[rng.nextInt(t.nouns.count)]
  return "\(genre) \u{00b7} \(adj) \(noun)"
}

private let drumRoles: Set<String> = ["kick", "snare", "hihat", "clap"]

private func groupFor(_ key: String) -> String? {
  if ["kick", "snare", "hihat", "clap", "tom", "perc"].contains(key) { return "drums" }
  if key == "bass" { return "bass" }
  if key == "melody" || key == "lead" { return "melody" }
  if key == "arp" { return "arp" }
  if ["pad", "chord", "chords", "harmony"].contains(key) { return "harmony" }
  if isStingerID(key) { return "stinger" }
  return nil
}

/// `fallbackInstrumentSet(groupOrRole, currentInstrument)`
public func fallbackInstrumentSet(_ groupOrRole: String, current: String) -> [String] {
  let t = BeatsTables.shared
  if groupOrRole == "stinger" { return t.stingerInstrumentSet }
  if let set = t.fallbackSet(groupOrRole), set.count > 1 {
    if !current.isEmpty && !set.contains(current) { return [current] + set }
    return set
  }
  var out: [String] = []
  let generic = [
    current.isEmpty ? "piano" : current, "piano", "electric-piano", "bass", "sub-bass", "lead",
    "sync-lead", "pad", "warm-pad", "strings", "organ", "fm-bell", "marimba",
  ]
  for v in generic where !v.isEmpty && !out.contains(v) { out.append(v) }
  return out
}

private func ensureGroupAndInstrumentSet(_ proj: inout Project) {
  for id in proj.nets.keys {
    guard var bundle = proj.nets[id], bundle.role != "control" else { continue }
    let key = bundle.riffGroup.isEmpty ? id : bundle.riffGroup
    if bundle.track.group == nil || bundle.track.group!.isEmpty {
      if let g = groupFor(key) { bundle.track.group = g }
    }
    if bundle.track.instrumentSet.count < 2 {
      let set = fallbackInstrumentSet(bundle.track.group ?? key, current: bundle.track.instrument)
      bundle.track.instrumentSet = set.map { .string($0) }
      if bundle.track.instrument.isEmpty && !set.isEmpty { bundle.track.instrument = set[0] }
    }
    proj.nets[id] = bundle
  }
}

private func addStingerTracks(_ proj: inout Project, seed: Double) {
  let t = BeatsTables.shared
  for spec in t.stingerSpecs {
    if proj.nets[spec.id] != nil { continue }
    var p = GenParams()
    p.channel = spec.channel
    p.velocity = 95
    p.duration = 80
    p.seed = seed
    p.accent = .none
    var bundle = euclidean(4, 16, 0, 60, p)
    bundle.track.instrument = spec.defaultInstrument
    bundle.track.instrumentSet = t.stingerInstrumentSet.map { .string($0) }
    bundle.track.group = "stinger"
    proj.nets[spec.id] = bundle
    if !proj.initialMutes.contains(spec.id) { proj.initialMutes.append(spec.id) }
  }
}

// MARK: - expandVariants

private func expandVariants(
  _ proj: inout Project, tmpl: inout SongTemplate, genre: GenreDef, rng: inout Mulberry32,
  tensionCurve: Bool, theme: TrackTheme?, tech: TechniqueContext? = nil
) {
  var rolesInPhrases = OrderedFlags()
  for sec in tmpl.sections { for role in sec.phrases.keys { rolesInPhrases.set(role) } }

  for role in rolesInPhrases.keys {
    guard let baseBundle = proj.nets[role] else { continue }
    let isDrum = drumRoles.contains(role)

    var slotMap: [[Int]] = []
    var slotIdx = 0
    var totalSlots = 0
    var letterSlots: [String: Int] = [:]

    for sec in tmpl.sections {
      let phrases = sec.phrases[role] ?? ["A"]
      var sectionSlots: [Int] = []
      if sec.active.contains(role) {
        for letter in phrases {
          if isDrum {
            if let s = letterSlots[letter] {
              sectionSlots.append(s)
            } else {
              letterSlots[letter] = slotIdx
              sectionSlots.append(slotIdx)
              slotIdx += 1
              totalSlots += 1
            }
          } else {
            sectionSlots.append(slotIdx)
            slotIdx += 1
            totalSlots += 1
          }
        }
      } else {
        sectionSlots = [Int](repeating: -1, count: phrases.count)
      }
      slotMap.append(sectionSlots)
    }
    tmpl.slotMap[role] = slotMap
    if totalSlots <= 1 { continue }

    for (si, sec) in tmpl.sections.enumerated() {
      let phrases = sec.phrases[role] ?? ["A"]
      for (pi, letter) in phrases.enumerated() {
        let idx = slotMap[si][pi]
        if idx < 0 { continue }
        let slotNetId = "\(role)-\(idx)"
        if proj.nets[slotNetId] != nil { continue }

        if isDrum {
          let spec: [Int]
          switch role {
          case "kick": spec = genre.kick
          case "snare": spec = genre.snare
          case "hihat": spec = genre.hihat
          default: spec = genre.snare
          }
          var params = GenParams()
          params.channel = baseBundle.track.channel
          params.velocity = baseBundle.track.defaultVelocity
          params.duration = 50
          params.seed = drumSeed("\(genre.name):\(role):\(letter)")
          switch role {
          case "kick": params.accent = .kick
          case "snare": params.accent = .snare
          case "hihat": params.accent = .hihat
          default: params.accent = .none
          }
          let style = genre.theory?.drumStyles[role]?[letter]
          var nb = drumRiff(
            variant: letter, hits: spec[0], steps: spec[1], rotation: spec[2], note: spec[3],
            params: params, style: style)
          nb.riffGroup = role
          nb.riffVariant = letter
          nb.track = baseBundle.track
          proj.nets[slotNetId] = nb
        } else {
          var scale: [Int]
          var rootNote: Int
          var density: Double
          let duration: Int
          if role == "bass" {
            scale = genre.scale(genre.rootNote)
            if scale.count > majorIntervals.count { scale = Array(scale[0..<majorIntervals.count]) }
            rootNote = genre.rootNote
            density = genre.bassDensity
            duration = genre.bassDuration
          } else {
            rootNote = genre.rootNote + 12
            scale = genre.scale(rootNote)
            density = genre.melodyDensity
            duration = genre.melodyDuration
          }
          var vel = baseBundle.track.defaultVelocity
          // bassFollow: every bass slot plays the same pattern (no per-letter tension).
          let follow = role == "bass" && tech?.t.bassFollow == true
          if tensionCurve && !follow {
            let tension = tensionForVariant(letter)
            density *= tension.densityMul
            if density > 1.0 { density = 1.0 }
            vel += tension.velocityAdd
            // keyLock: the shift is in semitones and moves the scale's root (a B phrase
            // plays a tone higher, in another key); with it the phrase stays in key.
            if tech?.t.keyLock != true {
              rootNote += tension.registerShift
              scale = genre.scale(rootNote)
              if role == "bass" && scale.count > majorIntervals.count {
                scale = Array(scale[0..<majorIntervals.count])
              }
            }
          }
          var params = GenParams()
          params.scale = scale
          params.rootNote = rootNote
          params.channel = baseBundle.track.channel
          params.velocity = vel
          params.duration = duration
          params.density = density
          params.seed = Double(rng.nextInt63())
          params.durationVariation = genre.durationVariation

          var nb: NetBundle
          if let tech, let hook = tech.hook, role == "melody" {
            let cell = renderHook(
              hook, mode: hookModes[sec.name] ?? MotifMode.play, plan: tech.plan)
            nb = motifNet(cell, scale: tech.melodyScale, params: params)
          } else if let tech, let hook = tech.hook, role == "arp", let theme,
            let mode = theme.energy[sec.name]?.roles[role]?.motifMode, mode != MotifMode.ignore
          {
            nb = motifNet(
              renderHook(hook, mode: mode, plan: tech.plan), scale: tech.melodyScale,
              params: params)
          } else if follow, theme == nil, let tech {
            var p = params
            p.seed = tech.bassSeed
            nb = followBassRing(tech.plan, scale: tech.bassScale, params: p)
          } else if let theme {
            let prof = theme.energy[sec.name]
            let roleProf = follow ? nil : prof?.roles[role]
            let mode = roleProf?.motifMode
            let harmonicOffset = theme.harmonic[sec.name] ?? 0
            if role == "bass" {
              if theme.groove == Groove.walking {
                nb = chordWalkingBassRing(
                  theme.plan, scale: scale, params: params,
                  registerShift: roleProf?.registerShift ?? 0)
              } else if theme.groove == Groove.bossa {
                nb = chordBossaBassRing(
                  theme.plan, scale: scale, params: params,
                  registerShift: roleProf?.registerShift ?? 0, bpm: genre.bpm)
              } else {
                let bMask = grooveLock(kickHitMask(genre), template: theme.groove)
                nb = chordBassRing(
                  theme.plan, barMask: bMask, scale: scale, params: params,
                  registerShift: roleProf?.registerShift ?? 0)
              }
            } else if role == "melody" || role == "arp" {
              if mode == nil || mode == MotifMode.ignore {
                nb = melodyRiff(variant: letter, params: params)
              } else {
                var cell = renderMotif(theme.motif, mode: mode!, harmonicOffset: harmonicOffset)
                if role == "melody", let d = tech?.t.melodyDensity { cell = thinCell(cell, density: d) }
                nb = motifNet(cell, scale: scale, params: params)
              }
            } else {
              nb = melodyRiff(variant: letter, params: params)
            }
          } else {
            nb = melodyRiff(variant: letter, params: params)
          }
          if let tech, role == "melody" || (role == "arp" && tech.t.chordSnapArp) {
            snapToChords(&nb, tech, mode: tech.t.chordSnap)
          }
          nb.riffGroup = role
          nb.riffVariant = letter
          nb.track = baseBundle.track
          proj.nets[slotNetId] = nb
        }
      }
    }
    proj.nets[role] = nil
  }
}

// MARK: - compose

private func override(_ ov: JSONValue, _ key: String) -> JSONValue? { ov[key] }

/// `compose(genreName, overrides)`. `overrides` is the JS overrides object (a JSON
/// object); without a numeric `seed` the wall clock is used, as in JS.
public func compose(genre genreName: String, overrides ov: JSONValue = .object(JSONObject()))
  -> Project
{
  let tables = BeatsTables.shared
  var genre = tables.genres[genreName] ?? tables.genres["techno"]!
  if let v = ov["melodyDensity"]?.double { genre.melodyDensity = v }
  if let v = ov["bassDensity"]?.double { genre.bassDensity = v }
  let tech = ComposeTechniques(ov)

  let seed = ov["seed"]?.double ?? Double(Int(Date().timeIntervalSince1970 * 1000))
  var rng = Mulberry32(seed: seed)

  let bpm = ov["bpm"]?.double ?? genre.bpm

  var df = ov["drum-fills"]?.bool ?? genre.drumFills
  let wb = ov["walking-bass"]?.bool ?? genre.walkingBass
  var polySteps = genre.polyrhythm
  if let v = ov["polyrhythm"]?.double { polySteps = Int(v) }
  let sync = ov["syncopation"]?.double ?? genre.syncopation
  let cr = ov["call-response"]?.bool ?? genre.callResponse
  let tc = ov["tension-curve"]?.bool ?? genre.tensionCurve
  let mi = ov["modal-interchange"]?.double ?? genre.modalInterchange
  let gn = ov["ghost-notes"]?.double ?? genre.ghostNotes

  var cohesion = "v2"
  if let c = ov["cohesion"]?.string, !c.isEmpty { cohesion = c }
  let theme: TrackTheme? =
    (cohesion == "v2" && cohesionGenreSupported(genreName))
    ? buildTrackTheme(genre: genreName, seed: seed) : nil
  let ctx = techniqueContext(tech, genre: genre, genreName: genreName, seed: seed, theme: theme)

  var proj = Project()
  proj.name = generateTrackName(genre: genre.name, seed: seed)
  proj.tempo = bpm
  proj.swing = genre.swing
  proj.humanize = ov["humanize"]?.double ?? genre.humanize
  proj.rootNote = genre.rootNote
  proj.scaleName =
    genre.scaleName.hasSuffix("Scale") ? String(genre.scaleName.dropLast(5)) : genre.scaleName
  proj.bars = max(
    1, Int(jsRound(Double(genre.kick.count > 1 && genre.kick[1] != 0 ? genre.kick[1] : 16) / 16)))
  if theme != nil { proj.cohesion = "v2" }

  // === Drums ===
  let dSeed = drumSeed(genreName)
  var kickP = GenParams()
  kickP.channel = 10
  kickP.velocity = 100
  kickP.duration = 50
  kickP.seed = dSeed
  kickP.accent = .kick
  proj.nets["kick"] = euclidean(genre.kick[0], genre.kick[1], genre.kick[2], genre.kick[3], kickP)

  var snareP = kickP
  snareP.channel = 11
  snareP.seed = dSeed + 1
  snareP.accent = .snare
  proj.nets["snare"] = euclidean(
    genre.snare[0], genre.snare[1], genre.snare[2], genre.snare[3], snareP)

  var hihatHits = genre.hihat[0]
  var hihatSteps = genre.hihat[1]
  let hihatRotation = genre.hihat[2]
  let hihatNote = genre.hihat[3]
  if polySteps > 0 {
    hihatSteps = polySteps
    hihatHits = max(1, Int((Double(hihatHits * polySteps) / Double(genre.hihat[1])).rounded(.down)))
  }
  var hihatP = kickP
  hihatP.channel = 12
  hihatP.seed = dSeed + 2
  hihatP.accent = .hihat
  if gn > 0 {
    proj.nets["hihat"] = ghostNoteHihat(
      hits: hihatHits, steps: hihatSteps, rotation: hihatRotation, note: hihatNote,
      params: hihatP, ghostDensity: gn)
  } else {
    proj.nets["hihat"] = euclidean(hihatHits, hihatSteps, hihatRotation, hihatNote, hihatP)
  }

  // Chord progression
  var chordProg: ChordProg
  if let progs = genre.theory?.chordProgs, !progs.isEmpty {
    chordProg = progs[rng.nextInt(progs.count)]
  } else {
    chordProg = tables.minorChordProg
    let test = genre.scale(60)
    if test.count >= 7 && test[2] - test[0] == 4 { chordProg = tables.majorChordProg }
  }
  if mi > 0 {
    chordProg = applyModalInterchange(
      chordProg, scale: genre.scale(60), probability: mi, rng: &rng)
  }

  // Bass
  var bassScale = genre.scale(genre.rootNote)
  if bassScale.count > majorIntervals.count {
    bassScale = Array(bassScale[0..<majorIntervals.count])
  }
  var bassP = GenParams()
  bassP.scale = bassScale
  bassP.rootNote = genre.rootNote
  bassP.channel = genre.bassChannel
  bassP.velocity = 90
  bassP.duration = genre.bassDuration
  bassP.density = genre.bassDensity
  bassP.seed = Double(rng.nextInt63())
  bassP.chords = chordProg
  bassP.durationVariation = genre.durationVariation
  bassP.syncopation = sync
  if let theme {
    if theme.groove == Groove.walking {
      proj.nets["bass"] = chordWalkingBassRing(
        theme.plan, scale: bassScale, params: bassP, registerShift: 0)
    } else if theme.groove == Groove.bossa {
      proj.nets["bass"] = chordBossaBassRing(
        theme.plan, scale: bassScale, params: bassP, registerShift: 0, bpm: genre.bpm)
    } else {
      let bMask = grooveLock(kickHitMask(genre), template: theme.groove)
      proj.nets["bass"] = chordBassRing(
        theme.plan, barMask: bMask, scale: bassScale, params: bassP)
    }
  } else if let ctx, tech.bassFollow {
    var p = bassP
    p.seed = ctx.bassSeed
    proj.nets["bass"] = followBassRing(ctx.plan, scale: ctx.bassScale, params: p)
  } else if wb {
    proj.nets["bass"] = walkingBassLine(bassP)
  } else {
    proj.nets["bass"] = markovMelody(bassP)
  }

  // Melody
  let melodyRoot = genre.rootNote + 12
  var melodyP = GenParams()
  melodyP.scale = genre.scale(melodyRoot)
  melodyP.rootNote = melodyRoot
  melodyP.channel = genre.melodyChannel
  melodyP.velocity = 85
  melodyP.duration = genre.melodyDuration
  melodyP.density = genre.melodyDensity
  melodyP.seed = Double(rng.nextInt63())
  melodyP.chords = chordProg
  melodyP.durationVariation = genre.durationVariation
  melodyP.syncopation = sync
  if let theme {
    let motif = tech.melodyDensity.map { thinCell(theme.motif, density: $0) } ?? theme.motif
    proj.nets["melody"] = motifNet(motif, scale: melodyP.scale, params: melodyP)
    let barMs = Int((4.0 * 60000.0 / bpm * 0.95).rounded(.down))
    var padP = GenParams()
    padP.channel = 7
    padP.velocity = 68
    padP.duration = barMs
    var pad = chordPadNet(theme.plan, scale: genre.scale(genre.rootNote), params: padP)
    pad.track.instrument = genreName == "synthwave" ? "warm-pad" : "dark-pad"
    proj.nets["harmony"] = pad
  } else if cr {
    proj.nets["melody"] = callResponseMelody(melodyP)
  } else {
    proj.nets["melody"] = markovMelody(melodyP)
  }
  if let ctx {
    if let hook = ctx.hook {
      proj.nets["melody"] = motifNet(
        renderHook(hook, mode: MotifMode.play, plan: ctx.plan), scale: ctx.melodyScale,
        params: melodyP)
    }
    snapToChords(&proj.nets["melody"]!, ctx, mode: tech.chordSnap)
  }

  // Genre-specific extras
  if genreName == "edm" || genreName == "synthwave" || genreName == "trance" {
    if genreName == "edm" {
      var clapP = GenParams()
      clapP.channel = 13
      clapP.velocity = 100
      clapP.duration = 50
      clapP.seed = dSeed + 3
      clapP.accent = .snare
      proj.nets["clap"] = euclidean(2, 16, 4, 39, clapP)
    }
    var arpScale = genre.scale(genre.rootNote + 24)
    if arpScale.count > 5 { arpScale = Array(arpScale[0..<5]) }
    var arpP = GenParams()
    arpP.channel = 5
    arpP.velocity = 80
    arpP.duration = 60
    proj.nets["arp"] = euclideanMelodic(
      arpScale, steps: 16, seed: Double(rng.nextInt63()), arpP)
    if let ctx, tech.chordSnapArp { snapToChords(&proj.nets["arp"]!, ctx, mode: tech.chordSnap) }
  }

  // Assign instruments
  if let sets = tables.instrumentSets[genreName] {
    var roleInstrument: [String: String] = [:]
    for (role, instruments) in sets.pairs {
      roleInstrument[role] = instruments[rng.nextInt(instruments.count)]
    }
    for id in proj.nets.keys {
      var bundle = proj.nets[id]!
      let lookupKey = bundle.riffGroup.isEmpty ? id : bundle.riffGroup
      if let instruments = sets[lookupKey], !instruments.isEmpty {
        bundle.track.instrumentSet = instruments.map { .string($0) }
        bundle.track.instrument = roleInstrument[lookupKey] ?? instruments[0]
        proj.nets[id] = bundle
      }
    }
  }

  // Tag every music net with its mixer group + guarantee an instrumentSet of ≥ 2.
  for id in proj.nets.keys {
    var bundle = proj.nets[id]!
    if bundle.role == "control" { continue }
    let key = bundle.riffGroup.isEmpty ? id : bundle.riffGroup
    let group = groupFor(key)
    if let group { bundle.track.group = group }
    if bundle.track.instrumentSet.count < 2 {
      let set = fallbackInstrumentSet(group ?? key, current: bundle.track.instrument)
      bundle.track.instrumentSet = set.map { .string($0) }
      if bundle.track.instrument.isEmpty { bundle.track.instrument = set[0] }
    }
    proj.nets[id] = bundle
  }

  // Override instruments
  if let inst = ov["instruments"]?.object {
    for id in proj.nets.keys {
      var bundle = proj.nets[id]!
      var name = inst[id]
      if name == nil || !(name!.isTruthy), !bundle.riffGroup.isEmpty {
        name = inst[bundle.riffGroup]
      }
      if let n = name?.string, !n.isEmpty {
        bundle.track.instrument = n
        proj.nets[id] = bundle
      }
    }
  }

  // Chorus
  if ov["chorus"]?.bool == true { addChorus(&proj, genre: genre, rng: &rng) }

  // Structure mode
  if let structName = ov["structure"]?.string, !structName.isEmpty {
    var tmpl = generateStructure(genre: genreName, size: structName, rng: &rng)

    if let theme {
      for i in 0..<tmpl.sections.count {
        let name = tmpl.sections[i].name
        if let prof = theme.energy[name], prof.roles.count > 0 {
          tmpl.sections[i].active = OrderedFlags(
            prof.roles.pairs.filter { $0.value.active }.map(\.key))
          let pattern = defaultPhrases(name)
          var newPhrases = OrderedMap<[String]>()
          for role in tmpl.sections[i].active.keys where role != "snare" && role != "harmony" {
            newPhrases[role] = pattern
          }
          tmpl.sections[i].phrases = newPhrases
        }
      }
    }

    for i in 0..<tmpl.sections.count {
      for role in tmpl.sections[i].phrases.keys {
        tmpl.sections[i].phrases[role] = genrePhrases(genre.theory, tmpl.sections[i].name)
      }
    }

    if theme != nil { df = true }

    expandVariants(
      &proj, tmpl: &tmpl, genre: genre, rng: &rng, tensionCurve: tc, theme: theme, tech: ctx)
    if let budget = tech.layerBudget { applyLayerBudget(&tmpl, budget: budget) }

    if df {
      var pos = 0
      var fillIdx = 0
      for sec in tmpl.sections {
        pos += sec.steps
        if pos > 4 {
          let fillLen = sec.steps >= 128 ? 8 : 4
          proj.nets["fill-\(fillIdx)"] = drumFillNet(boundaryStep: pos, fillLength: fillLen)
          fillIdx += 1
        }
      }
    }

    let musicNets = proj.nets.keys
    proj.initialMutes = songStructure(&proj, template: tmpl, musicNets: musicNets)
    let totalSteps = proj.structure.reduce(0) { $0 + $1.steps }
    if totalSteps > 0 { proj.bars = max(1, Int(jsRound(Double(totalSteps) / 16))) }

    if let theme {
      var feel: [FeelPoint] = []
      for sec in tmpl.sections {
        if let prof = theme.energy[sec.name] {
          feel.append(FeelPoint(section: sec.name, x: prof.energy, y: prof.filterOpen))
        }
      }
      if !feel.isEmpty { injectFeelCurve(&proj, tmpl: tmpl, curve: feel) }
    }

    if let mc = ov["macroCurve"]?.array, !mc.isEmpty {
      injectMacroCurve(&proj, tmpl: tmpl, curve: mc)
    }

    addStingerTracks(&proj, seed: Double(rng.nextInt63()))
    ensureGroupAndInstrumentSet(&proj)
    proj.stampDurationSteps()
    return proj
  }

  // Loop mode: fade-in/out/break
  var melodicTargets = ["bass", "melody"]
  if proj.nets["arp"] != nil { melodicTargets.append("arp") }
  if proj.nets["harmony"] != nil { melodicTargets.append("harmony") }

  if ov["fade-in"]?.bool == true {
    _ = rng.nextInt63()
    proj.initialMutes = fadeIn(&proj, targets: melodicTargets, steps: 32)
  }
  if ov["fade-out"]?.bool == true {
    _ = rng.nextInt63()
    fadeOut(&proj, targets: melodicTargets, steps: 32)
  }
  if ov["drum-break"]?.bool == true {
    var breakTargets = ["bass", "melody"]
    if proj.nets["harmony"] != nil { breakTargets.append("harmony") }
    _ = rng.nextInt63()
    drumBreak(&proj, targets: breakTargets, cycleLen: 64, breakLen: 8)
  }

  addStingerTracks(&proj, seed: Double(rng.nextInt63()))
  ensureGroupAndInstrumentSet(&proj)
  proj.stampDurationSteps()
  return proj
}
