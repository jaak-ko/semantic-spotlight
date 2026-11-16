"""Eval queries. kind: mono (same language, relevant = same-language twin),
xl (query language differs from the relevant doc), id (exact code, relevant = doc holding it)."""

TOPICS = ["t%02d" % i for i in range(1, 21)]

FI_MONO = [
    "miten kardemummapullia leivotaan", "kunnan tietoaineistojen siirron suunnitelma",
    "retkeily Lapissa teltan kanssa", "nikotiinikorvaushoidon käyttö lopettamisessa",
    "nivelreuman lääkitys ja sen sivuvaikutukset", "sähkölaskun maksaminen ja sopimuksen tarkistus",
    "tomaattien ja basilikan istutus parvekkeella", "asunnon vuokrasopimus ja takuuvuokra",
    "koiran noutokäskyn opettaminen", "pakasteiden säilytys ja elintarviketurvallisuus",
    "työajan kirjaaminen tuntilomakkeeseen", "kuntosaliohjelma ja kuormituksen lisääminen",
    "verkkokaupasta palautettu tilaus ja palautusehdot", "lapsen nukkumaanmenorutiini",
    "salasanojen hallinta ja kaksivaiheinen tunnistautuminen", "vesivahinko kotona ja vakuutuskorvaus",
    "kirjastokortin uusiminen ja lainojen eräpäivä", "auton katsastus ja jarrupalat",
    "ruokavalio sydämen terveyteen ja omega-3", "kaupungin tulvasuojelu ilmastonmuutoksen aikana",
]

EN_MONO = [
    "how to bake cardamom buns", "municipal data migration plan",
    "hiking in Lapland with a tent", "nicotine replacement therapy to quit smoking",
    "rheumatoid arthritis medication and side effects", "paying the electricity bill and reviewing the contract",
    "planting tomatoes and basil on the balcony", "rental agreement and deposit",
    "teaching a dog to come when called", "frozen food storage and food safety",
    "logging working hours on the timesheet", "gym workout program and progressive overload",
    "returning an online order and the return policy", "child bedtime routine",
    "password management and two-factor login", "water damage at home and insurance compensation",
    "renewing library card and loan due dates", "car inspection and brake pads",
    "diet for heart health and omega-3", "city flood protection during climate change",
]

XL_FI2EN = [  # Finnish query, English relevant doc
    ("kunnan datan siirto", "t02"), ("nivelreuman hoito", "t05"),
    ("kuntoilu ja painojen nostaminen", "t12"), ("vesivahingon korvaus", "t16"),
    ("tulvariski kaupungissa", "t20"),
]
XL_EN2FI = [  # English query, Finnish relevant doc
    ("camping trip in northern Finland", "t03"), ("growing herbs on a balcony", "t07"),
    ("defrosting and storing food safely", "t10"), ("toddler sleep schedule", "t14"),
    ("library renewal and late fees", "t17"),
]

ID_QUERIES = [  # code appears only in the FI doc of each topic
    ("PULLA-204", "t01"), ("RETKI-118", "t03"), ("NIK-7731", "t04"), ("LASKU-88213", "t06"),
    ("VUOKRA-5520", "t08"), ("AIKA-3307", "t11"), ("RMA-3390", "t13"), ("VAHINKO-0412", "t16"),
    ("KATS-2290", "t18"), ("SYDAN-1177", "t19"),
]


NAME_QUERIES = [  # the eval docs of these names hold none of the query words in their text
    ("Thomas Sowell", "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt"),
    ("sosiaalinen oikeudenmukaisuus", "Thomas Sowell, sosiaalinen oikeudenmukaisuus.txt"),
    ("IMG_1723", "IMG_1723.txt"), ("Lahti 2026", "Asunto Lahti 2026.txt"),
]


def build():
    out = []
    for q, t in zip(FI_MONO, TOPICS):
        out.append({"q": q, "lang": "fi", "kind": "mono", "rel": f"{t}_fi.txt"})
    for q, t in zip(EN_MONO, TOPICS):
        out.append({"q": q, "lang": "en", "kind": "mono", "rel": f"{t}_en.txt"})
    for q, t in XL_FI2EN:
        out.append({"q": q, "lang": "fi", "kind": "xl", "rel": f"{t}_en.txt"})
    for q, t in XL_EN2FI:
        out.append({"q": q, "lang": "en", "kind": "xl", "rel": f"{t}_fi.txt"})
    for q, rel in NAME_QUERIES:  # words that are only in the file name
        out.append({"q": q, "lang": "name", "kind": "name", "rel": rel})
    for q, t in ID_QUERIES:
        out.append({"q": q, "lang": "id", "kind": "id", "rel": f"{t}_fi.txt"})
    return out


QUERIES = build()
assert len(QUERIES) == 64

# Off-topic queries about things the corpus does not contain. Any hit is junk.
JUNK = [
    "parhaat pizzeriat Helsingissä", "raketin laukaisuaikataulu Kaliforniasta",
    "kryptovaluutan louhintalaitteen kokoaminen", "kitaran soinnut bluesiin",
    "jääkiekkomailan valinta lapselle",
    "best pizza place in Rome", "rocket launch schedule for SpaceX",
    "cryptocurrency mining rig setup", "guitar chords for a blues song",
    "how to choose a hockey stick for kids",
]
