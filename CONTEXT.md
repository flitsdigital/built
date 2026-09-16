# Built

Persoonlijke gym- en eet-app: trainen, wegen, eten loggen — en sinds kort een kookboek.
Eén gebruiker per account; de telefoon van de eigenaar is het kookboek.

## Language

### Eten

**Maaltijdmoment**:
Ontbijt, lunch, diner of snack — het vak van de dag waarin je iets logt.
_Avoid_: maaltijd, slot

**Vaste maaltijd**:
Iets dat je vaak eet en met één tik logt, met eiwit/kcal per portie. Bestaat om te loggen, niet om te bewaren. (In code: `Meal`.)
_Avoid_: recept, gerecht

**Product**:
Een los voedingsmiddel met macro's per 100 g/ml, uit OpenFoodFacts of zelf ingevoerd.

### Kookboek

**Gerecht**:
Een recept dat jullie gemaakt hebben of nog willen maken: naam, link naar het recept, foto, sterren en ingrediënten. Bestaat om te onthouden en te kiezen, niet om te loggen.
_Avoid_: recept, maaltijd, meal

**Recept**:
De ingrediënten en bereidingsstappen van een gerecht, zoals overgenomen van de site of zelf getikt. Staat in de app; de link is alleen nog de **Bron**.

**Kookbeurt**:
Eén keer dat een gerecht gemaakt wordt: een dag, een notitie, en afgevinkt of niet. Niet afgevinkt = gepland of bezig; afgevinkt = gemaakt.
_Avoid_: planning, log, sessie

**Sterren**:
Het oordeel over een gerecht, 1–5, één per gerecht, van de eigenaar. Verandert mee met de laatste mening.
_Avoid_: rating, score, cijfer

**Label**:
Een woord dat je op een gerecht plakt om 'm terug te vinden (pasta, snel, vega).
_Avoid_: tag, categorie

**Nog te proberen**:
Een gerecht zonder afgevinkte kookbeurt. Afgeleid, geen eigen status.
_Avoid_: wensenlijst, bewaard
