#!/usr/bin/env python3
"""Genereert Built/ExerciseGuide.swift en ExerciseMedia/ uit de exercises-dataset.

    python3 scripts/exercises.py ~/pad/naar/exercises-dataset

Bron: https://github.com/hasaneyldrm/exercises-dataset (data MIT). De media is
eigendom van Gym visual (gymvisual.com) en zit hier alleen voor eigen gebruik.

De catalogus hieronder is met de hand gekozen: de dataset heeft geen populariteits-
signaal en z'n eigen namen zijn onbruikbaar lang ("cable standing reverse grip one
arm overhead tricep extension"). Links staat de naam zoals de app 'm toont, rechts de
rij in de dataset.
"""
import json, re, shutil, sys
from pathlib import Path

# ── De 31 uit de bestaande seed ───────────────────────────────────────────────
# Naam, spier en type blijven exact zoals ze zijn: sets en routines koppelen op naam,
# en `muscle` bepaalt onder welke spiergroep je historische volume valt. Alleen de
# meewerkende spieren, het plaatje en de uitleg komen uit de dataset.
BESTAAND = [
    ("Bench Press",            "Borst",       "Barbell",    "barbell bench press"),
    ("Incline Dumbbell Press", "Borst",       "Dumbbell",   "dumbbell incline bench press"),
    ("Dumbbell Press",         "Borst",       "Dumbbell",   "dumbbell bench press"),
    ("Chest Fly",              "Borst",       "Kabel",      "cable middle fly"),
    ("Push Up",                "Borst",       "Bodyweight", "push-up"),
    ("Shoulder Press",         "Schouders",   "Barbell",    "barbell seated overhead press"),
    ("Overhead Press",         "Schouders",   "Barbell",    None),
    ("Lateral Raises",         "Schouders",   "Dumbbell",   "dumbbell lateral raise"),
    ("Face Pulls",             "Schouders",   "Kabel",      None),
    ("Triceps Pushdown",       "Triceps",     "Kabel",      "cable pushdown"),
    ("Triceps Extension",      "Triceps",     "Dumbbell",   "dumbbell standing triceps extension"),
    ("Dips",                   "Triceps",     "Bodyweight", "triceps dip"),
    ("Deadlift",               "Rug",         "Barbell",    "barbell deadlift"),
    ("Lat Pulldown",           "Rug",         "Machine",    "cable pulldown"),
    ("Barbell Row",            "Rug",         "Barbell",    "barbell bent over row"),
    ("Pull Up",                "Rug",         "Bodyweight", "pull-up"),
    ("Seated Row",             "Rug",         "Kabel",      "cable seated row"),
    ("Biceps Curl",            "Biceps",      "Dumbbell",   "dumbbell biceps curl"),
    ("Barbell Curl",           "Biceps",      "Barbell",    "barbell curl"),
    ("Hammer Curl",            "Biceps",      "Dumbbell",   "dumbbell hammer curl"),
    ("Squat",                  "Benen",       "Barbell",    "barbell full squat"),
    ("Leg Press",              "Benen",       "Machine",    "sled 45° leg press (side pov)"),
    ("Leg Extension",          "Benen",       "Machine",    "lever leg extension"),
    ("Lunges",                 "Benen",       "Dumbbell",   "dumbbell lunge"),
    ("Romanian Deadlift",      "Hamstrings",  "Barbell",    "barbell romanian deadlift"),
    ("Leg Curl",               "Hamstrings",  "Machine",    "lever seated leg curl"),
    ("Hip Thrust",             "Bilspieren",  "Barbell",    None),
    ("Calf Raises",            "Kuiten",      "Machine",    "lever standing calf raise"),
    ("Plank",                  "Core",        "Bodyweight", None),
    ("Crunch",                 "Core",        "Bodyweight", "crunch floor"),
    ("Hanging Leg Raise",      "Core",        "Bodyweight", "hanging straight leg raise"),
]

CARDIO = ["Loopband", "Hardlopen", "Fietsen", "Hometrainer",
          "Roeimachine", "Crosstrainer", "Stairmaster", "Wandelen"]

# ── Erbij ─────────────────────────────────────────────────────────────────────
# Spier en type komen uit de dataset, tenzij hier een spier staat — de dataset zet
# `target` soms ergens waar de app 'm niet zou verwachten.
NIEUW = [
    # Borst
    ("Incline Barbell Bench Press",  None, "barbell incline bench press"),
    ("Decline Barbell Bench Press",  None, "barbell decline bench press"),
    ("Close-Grip Bench Press",       None, "barbell close-grip bench press"),
    ("Smith Machine Bench Press",    None, "smith bench press"),
    ("Machine Chest Press",          None, "lever chest press"),
    ("Pec Deck",                     None, "lever seated fly"),
    ("Dumbbell Fly",                 None, "dumbbell fly"),
    ("Incline Dumbbell Fly",         None, "dumbbell incline fly"),
    ("Cable Crossover",              None, "cable cross-over variation"),
    ("Low Cable Fly",                None, "cable low fly"),
    ("Incline Cable Fly",            None, "cable incline fly"),
    ("Dumbbell Pullover",            None, "dumbbell pullover"),
    ("Chest Dip",                    None, "chest dip"),
    ("Incline Push Up",              None, "incline push-up"),
    ("Decline Push Up",              None, "decline push-up"),
    ("Diamond Push Up",              None, "diamond push-up"),
    # Rug
    ("Sumo Deadlift",                "Rug", "barbell sumo deadlift"),
        ("Rack Pull",                    "Rug", "barbell rack pull"),
    ("Pendlay Row",                  None, "barbell pendlay row"),
    ("T-Bar Row",                    None, "lever t bar row"),
    ("Dumbbell Row",                 None, "dumbbell bent over row"),
    ("One-Arm Dumbbell Row",         None, "dumbbell one arm bent-over row"),
    ("Chest Supported Row",          None, "lever seated row"),
    ("Machine Row",                  None, "lever narrow grip seated row"),
    ("Wide-Grip Lat Pulldown",       None, "cable bar lateral pulldown"),
    ("V-Bar Lat Pulldown",           None, "cable lateral pulldown with v-bar"),
    ("Straight-Arm Pulldown",        None, "cable straight arm pulldown"),
    ("Chin Up",                      None, "chin-up"),
    ("Assisted Pull Up",             None, "assisted pull-up"),
    ("Inverted Row",                 None, "inverted row"),
    ("Barbell Shrug",                None, "barbell shrug"),
    ("Dumbbell Shrug",               None, "dumbbell shrug"),
    ("Back Extension",               None, "hyperextension"),
    ("Good Morning",                 None, "barbell good morning"),
    # Schouders
    ("Dumbbell Shoulder Press",      None, "dumbbell seated shoulder press"),
    ("Arnold Press",                 None, "dumbbell arnold press"),
    ("Machine Shoulder Press",       None, "lever shoulder press"),
    ("Cable Lateral Raise",          None, "cable lateral raise"),
    ("Front Raise",                  None, "dumbbell front raise"),
    ("Rear Delt Fly",                None, "dumbbell rear lateral raise"),
    ("Reverse Pec Deck",             None, "lever seated reverse fly"),
    ("Upright Row",                  None, "barbell upright row"),
    ("Cable Rear Delt Fly",          None, "cable supine reverse fly"),
    ("Dumbbell Push Press",          None, "dumbbell push press"),
    # Biceps
    ("EZ-Bar Curl",                  None, "ez barbell curl"),
    ("Preacher Curl",                None, "barbell preacher curl"),
    ("Incline Dumbbell Curl",        None, "dumbbell incline curl"),
    ("Concentration Curl",           None, "dumbbell concentration curl"),
    ("Cable Curl",                   None, "cable curl"),
    ("Spider Curl",                  None, "barbell lying preacher curl"),
    ("Machine Curl",                 None, "lever preacher curl"),
    ("Reverse Curl",                 None, "barbell reverse curl"),
    ("Wrist Curl",                   None, "barbell wrist curl"),
    # Triceps
    ("Skull Crusher",                None, "barbell lying triceps extension"),
    ("Overhead Cable Extension",     None, "cable overhead triceps extension (rope attachment)"),
    ("Rope Pushdown",                None, "cable pushdown (with rope attachment)"),
    ("Bench Dip",                    None, "bench dip on floor"),
    ("Kickback",                     None, "dumbbell kickback"),
    ("Dumbbell Overhead Extension",  None, "dumbbell seated triceps extension"),
    ("JM Press",                     None, "barbell jm bench press"),
    # Benen
    ("Front Squat",                  "Benen", "barbell front squat"),
    ("Hack Squat",                   "Benen", "sled lying squat"),
    ("Goblet Squat",                 "Benen", "kettlebell goblet squat"),
    ("Bulgarian Split Squat",        None, "dumbbell single leg split squat"),
    ("Smith Machine Squat",          "Benen", "smith squat"),
    ("Box Squat",                    None, "barbell bench squat"),
    ("Pause Squat",                  "Benen", "barbell full squat (side pov)"),
    ("Walking Lunge",                "Benen", "dumbbell rear lunge"),
    ("Step Up",                      "Benen", "dumbbell step-up"),
    ("Leg Press (Single Leg)",       "Benen", "lever horizontal one leg press"),
    ("Sissy Squat",                  None, "sissy squat"),
    ("Adductor Machine",             None, "lever seated hip adduction"),
    ("Abductor Machine",             None, "lever seated hip abduction"),
    # Hamstrings & bilspieren
    ("Stiff-Leg Deadlift",           None, "barbell straight leg deadlift"),
    ("Lying Leg Curl",               None, "lever lying leg curl"),
    ("Nordic Curl",                  None, "self assisted inverse leg curl"),
    ("Single-Leg Deadlift",          "Hamstrings", "barbell single leg deadlift"),
    ("Dumbbell RDL",                 "Hamstrings", "dumbbell romanian deadlift"),
    ("Glute Bridge",                 None, "glute bridge two legs on bench (male)"),
    ("Cable Kickback",               None, "cable standing hip extension"),
        # Kuiten
    ("Seated Calf Raise",            None, "lever seated calf raise"),
    ("Standing Calf Raise",          None, "barbell standing calf raise"),
    ("Calf Press",                   None, "sled calf press on leg press"),
    ("Dumbbell Calf Raise",          None, "dumbbell standing calf raise"),
    # Core
    ("Cable Crunch",                 None, "cable kneeling crunch"),
    ("Hanging Knee Raise",           None, "hanging leg hip raise"),
    ("Russian Twist",                None, "russian twist"),
    ("Side Plank",                   None, "side bridge v. 2"),
    ("Ab Wheel Rollout",             None, "wheel rollerout"),
    ("Leg Raise",                    None, "lying leg raise flat bench"),
    ("Bicycle Crunch",               None, "air bike"),
    ("Mountain Climber",             "Core", "mountain climber"),
    ("Sit Up",                       None, "sit-up v. 2"),
    ("Dead Bug",                     None, "dead bug"),
    ("Cable Woodchopper",            None, "cable twist (up-down)"),
    ("Machine Crunch",               None, "lever seated crunch"),
    # Overig / functioneel
    ("Farmers Walk",                 "Overig", "farmers walk"),
    ("Kettlebell Swing",             None, "kettlebell swing"),
    ("Clean and Press",              "Overig", "barbell clean and press"),
            ("Thruster",                     None, "barbell thruster"),
    ("Burpee",                       None, "burpee"),
]

SPIER = {
    "pectorals": "Borst", "lats": "Rug", "upper back": "Rug", "traps": "Rug",
    "delts": "Schouders", "biceps": "Biceps", "triceps": "Triceps",
    "quads": "Benen", "adductors": "Benen", "abductors": "Benen",
    "hamstrings": "Hamstrings", "glutes": "Bilspieren", "calves": "Kuiten",
    "abs": "Core", "serratus anterior": "Core", "spine": "Onderrug",
    "cardiovascular system": "Cardio", "forearms": "Overig",
    "levator scapulae": "Rug",
}

TYPE = {
    "barbell": "Barbell", "ez barbell": "Barbell", "olympic barbell": "Barbell",
    "trap bar": "Barbell", "dumbbell": "Dumbbell", "cable": "Kabel",
    "leverage machine": "Machine", "smith machine": "Machine", "sled machine": "Machine",
    "body weight": "Bodyweight", "weighted": "Bodyweight", "assisted": "Bodyweight",
    "kettlebell": "Kettlebell", "band": "Band", "resistance band": "Band",
    "stability ball": "Bodyweight", "medicine ball": "Bodyweight", "rope": "Bodyweight",
    "roller": "Bodyweight", "wheel roller": "Bodyweight", "bosu ball": "Bodyweight",
    "hammer": "Overig", "tire": "Overig",
    "stationary bike": "Cardio", "elliptical machine": "Cardio", "stepmill machine": "Cardio",
    "skierg machine": "Cardio", "upper body ergometer": "Cardio",
}

# De dataset kent 40 losse spiernamen; de app toont er een handvol die iemand herkent.
BIJSPIER = {
    "shoulders": "Schouders", "deltoids": "Schouders", "rear deltoids": "Achterste schouder",
    "rotator cuff": "Rotator cuff", "chest": "Borst", "upper chest": "Borst",
    "triceps": "Triceps", "biceps": "Biceps", "brachialis": "Biceps",
    "forearms": "Onderarmen", "wrists": "Onderarmen", "wrist flexors": "Onderarmen",
    "wrist extensors": "Onderarmen", "grip muscles": "Onderarmen", "hands": "Onderarmen",
    "back": "Rug", "upper back": "Rug", "lats": "Rug", "latissimus dorsi": "Rug",
    "rhomboids": "Rug", "trapezius": "Trapezius", "traps": "Trapezius",
    "lower back": "Onderrug", "core": "Core", "abdominals": "Core", "obliques": "Schuine buik",
    "lower abs": "Core", "hip flexors": "Heupbuigers", "glutes": "Bilspieren",
    "quadriceps": "Benen", "hamstrings": "Hamstrings", "adductors": "Adductoren",
    "inner thighs": "Adductoren", "groin": "Adductoren", "calves": "Kuiten",
    "soleus": "Kuiten", "shins": "Schenen", "ankles": "Enkels",
    "ankle stabilizers": "Enkels", "feet": "Enkels",
    "sternocleidomastoid": "Nek",
}


def swift(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1]).expanduser()
    root = Path(__file__).resolve().parent.parent
    media = root / "ExerciseMedia"

    data = json.loads((src / "data" / "exercises.json").read_text())
    index = {}
    for row in data:
        index.setdefault(row["name"].lower(), row)   # eerste wint bij een dubbele naam

    rows, missing = [], []
    for naam, spier, soort, bron in BESTAAND:
        rows.append((naam, spier, soort, index.get(bron) if bron else None, bron))
    for naam, spier, bron in NIEUW:
        row = index.get(bron)
        if row is None:
            missing.append((naam, bron))
            continue
        rows.append((naam, spier or SPIER.get(row["target"], "Overig"),
                     TYPE.get(row["equipment"], "Overig"), row, bron))
    for naam in CARDIO:
        rows.append((naam, "Cardio", "Cardio", None, None))

    for naam, spier, soort, row, bron in rows:
        if bron and row is None and (naam, bron) not in missing:
            missing.append((naam, bron))
    if missing:
        print("Niet gevonden in de dataset:", file=sys.stderr)
        for naam, bron in missing:
            print(f"  {naam!r} -> {bron!r}", file=sys.stderr)
        sys.exit(1)

    # Media: alleen wat we noemen, niet alle 1324.
    if media.exists():
        shutil.rmtree(media)
    media.mkdir()
    for _, _, _, row, _ in rows:
        if row is None:
            continue
        for key in ("image", "gif_url"):
            bestand = src / row[key]
            shutil.copy2(bestand, media / bestand.name)

    out = ["""// Gegenereerd door scripts/exercises.py — niet met de hand bijwerken.
//
// Bron: https://github.com/hasaneyldrm/exercises-dataset (data MIT).
// De media in ExerciseMedia/ is eigendom van Gym visual — https://gymvisual.com/ —
// en zit hier onder eigen licentie, alleen voor persoonlijk gebruik.

import Foundation

/// Wat de dataset over een oefening weet: het plaatje, de bewegende versie en de
/// uitleg. Los van `Exercise`, want dit is naslag die niet meesynchroniseert en
/// niet te bewerken is — het hoort niet in een rij die per toestel kan verschillen.
struct ExerciseGuide: Sendable {
    /// Bestandsnaam zonder extensie in ExerciseMedia/; `.jpg` is stil, `.gif` beweegt.
    let media: String
    let secondary: [String]
    let steps: [String]
}

enum ExerciseCatalog {
    /// Naam, spier, type — de standaardcatalogus die `Exercise.bootstrap` zaait.
    static let seed: [(name: String, muscle: String, type: String)] = ["""]
    for naam, spier, soort, _, _ in rows:
        out.append(f"        ({swift(naam)}, {swift(spier)}, {swift(soort)}),")
    out.append("    ]\n")
    out.append("    /// Naslag per oefeningnaam. Niet elke oefening heeft er een.")
    out.append("    static let guides: [String: ExerciseGuide] = [")
    for naam, _, _, row, _ in rows:
        if row is None:
            continue
        stem = Path(row["image"]).stem
        sec, seen = [], set()
        for m in row["secondary_muscles"]:
            nl = BIJSPIER.get(m)
            if nl and nl not in seen:
                seen.add(nl)
                sec.append(nl)
        steps = [re.sub(r"\s+", " ", s).strip() for s in row["instruction_steps"]["en"]]
        out.append(f"        {swift(naam)}: .init(")
        out.append(f"            media: {swift(stem)},")
        out.append(f"            secondary: [{', '.join(swift(s) for s in sec)}],")
        out.append("            steps: [")
        for s in steps:
            out.append(f"                {swift(s)},")
        out.append("            ]),")
    out.append("    ]")
    out.append("}")

    (root / "Built" / "ExerciseGuide.swift").write_text("\n".join(out) + "\n")
    met = sum(1 for r in rows if r[3])
    print(f"{len(rows)} oefeningen, {met} met plaatje en uitleg")
    print(f"media: {sum(f.stat().st_size for f in media.iterdir()) / 1e6:.0f} MB "
          f"in {len(list(media.iterdir()))} bestanden")


if __name__ == "__main__":
    main()
