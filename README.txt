PART ATTACHER - bet kokia detale ant bet kokios masinos (BeamNG.drive 0.40)
===========================================================================
Mod author: Kavencki - Giedrius P.        Versija: 1.0 beta
English: README_EN.txt
(c) 2026 Kavencki. Visos teises saugomos. Platinti, perkelti ar skelbti kaip
savo be autoriaus leidimo draudziama.


KALBA / LANGUAGE
-----------------
Lango apacioje "Language / Kalba": English (numatyta) arba Lietuviu.
Pasirinkimas issaugomas (settings/partAttacher/settings.json).
At the bottom of the window: "Language / Kalba" - English (default) or Lithuanian.
Vertimai: lua/ge/extensions/partAttacher/lang.lua

Kaip naudoti
------------
1. Isek i masina, ant kurios nori deti detale.
2. Spausk  Ctrl + Shift + Y  arba ESC > Mods > Part Attacher > "ATIDARYTI PART
   ATTACHER" (arba konsoleje:  partAttacher.toggleWindow() ).
   Klavisa galima pakeisti: Options > Controls > Gameplay > "Part Attacher".
3. "Modelis" - pasirink masina, IS KURIOS imsi detale (bet kuri masina ar mod'as).
   Detales suskirstytos aplankais (Front Bumper, Rear Bumper, Hood...). Arba ieskok.
4. "Sukurti detale" - atsiras PERZIUROS detale, kabanti ore virs tavo masinos.
5. Stumdyk X/Y/Z ir pasukimo slankiklius (Ctrl+click = ivesti skaiciu, -/+ = mazas
   zingsnis). "Donoro vieta" - ten, kur detale butu ant savo originalios masinos.
6. "PRITVIRTINTI (idiegti i masina)" - perziuros objektas dingsta, o tavo masina
   persikrauna SU ta detale savo jbeam'e. Detale tampa tikra masinos dalimi
   (ne atskira "masina"), privirinama prie artimiausiu tvirtu kebulo tasku sijomis
   tokio ilgio, koks yra tarpas - todel niekas netraukiama ir nelamdoma.
   Po R (reset) detale islieka.
7. "3. Idiegtos detales": "Perkelti" - nuima detale ir vel leidzia ja stumdyti,
   "Nuimti" - pasalina is masinos.

ENGINE SWAP (variklio keitimas)
-------------------------------
1. Isek i masina, kurios varikli nori pakeisti.
2. "Modelis" - masina, IS KURIOS imsi varikli. Sarase atsidaryk aplanka
   ">> VARIKLIO SWAP" - ten visi to modelio varikliai su ~kW, max rpm ir kuru.
   (kW - bazine kreive; turbo / ECU / internals detales prideda daugiau.)
3. "ENGINE SWAP - perziura" - naujas variklis atsiras toje vietoje, kur yra
   senasis (variklio centrai sulyginti). Pastumk / pasuk, jei reikia.
4. "ATLIKTI ENGINE SWAP" - LOGIC SWAP: tavo variklio fizika (blokas, pagalves,
   jungtys su pavaru deze) lieka gamykline, todel niekas nesulus ir nenuskris.
   Is donoro perkeliami visi variklio duomenys: galios / sukimo momento kreive,
   apsukos, inercija, turbo / kompresorius, ECU, internals, garsas (paimti is
   pilnai uzkrautos perziuros). Donoro variklio modelis pakeicia tavo variklio
   modeli (galima isjungti). Pavaru deze lieka tavo, kuras - tavo bako.
   TIUNINGAS: iprastame Parts meniu po varikliu atsiranda DONORO variklio
   slotai (ECU, internals, intake / turbo, kompresorius, N2O) - rinkis kaip
   iprastai. Jie ikeliami be fizikos (tik duomenys, garsas ir modelis).
5. "3. Idiegtos detales": "Perkelti" - grazina sena varikli ir leidzia nauja
   pastumdyti; "Grazinti originalu" - atsaukia swap'a.

GEARBOX SWAP (pavaru dezes keitimas)
------------------------------------
1. "Modelis" - masina, IS KURIOS imsi deze. Aplankas ">> PAVARU DEZES SWAP"
   (rodomas tipas: manual / automatic / dct / cvt / sequential).
2. "GEARBOX SWAP - perziura" -> pastumk, jei reikia -> "ATLIKTI GEARBOX SWAP".
3. "Kartu ijungti universalias pavaras" (rekomenduojama) - kad galia tikrai
   pasiektu ratus su bet kokia deze.

AUTO VIETA IR VEIDRODIS
-----------------------
- "Auto vieta" (1 dalis, ijungta): nauja detale atsiranda ten, kur stovi tavo
  masinos tokia pati detale (buferis ant buferio, kapotas ant kapoto) - slotai
  lyginami be modelio vardo (pickup_bumper_F ~ etk800_bumper_F). 2 dalyje
  mygtukas "Kaip mano masinos detale" grazina i ta vieta.
- "Veidrodine kopija" (2 dalis) ir "Veidrodis" (3 dalis): ta pati detale kitoje
  masinos puseje. Jei donoras turi kitos puses detale (door_FL -> door_FR,
  mirror_L -> mirror_R), imama ji; jei ne - ta pati, pastatyta veidrodiskai.
  Atsiranda perziura: pastumdyk, jei reikia, ir PRITVIRTINK.

DYDIS (scale)
-------------
- 2 dalyje "Dydis (scale)": detale sumazinama arba padidinama (x0.1 - x5,
  Ctrl+click - ivesti iki x10). Didinama / mazinama apie savo centra - ir
  modelis, ir fizika. Atleidus slankikli perziura persikrauna; "Tikras dydis"
  grazina x1. 3 dalyje rodomas dydis (pvz. x1.50), Perkelti / Veidrodis ji
  islaiko. Zibintai ir kiti "props" ant detales lieka savo dydzio.

SNORKELIS
---------
- Pritvirtintas snorkelis (ar bet kuri detale su oro paemimo taskais) veikia
  tikrai: variklis ima ora ir per ji, todel uzlieja tik tada, kai po vandeniu
  atsiduria ir snorkelio virsus (veikia ir kaip "Tik modelis"). last_load.log
  rasoma "the engine takes its air through it too".

TIK MODELIS (be fizikos, "static mesh")
--------------------------------------
- Varnele "Tik modelis (be fizikos)" 1 dalyje: detale atsiras tik kaip modelis -
  nesveria, nesimusa, nelusta, tik juda kartu su masina. Stumdyk kaip iprasta
  (X/Y/Z, pasukimas) ir spausk PRITVIRTINTI.
- Detales, kuriu modelis kabo ant savo masinos kebulo (radiatorius ir pan.),
  taip rodomos automatiskai - kitaip ju perziura butu nematoma.
- 3 dalyje tokia detale pazymeta "[tik modelis]". Mygtukas "Su fizika" ja
  toje pacioje vietoje pavercia detale su fizika (virtualus tvirtinimas),
  "Tik modelis" - atvirksciai.
- 2 dalyje rodomas perziuros rezimas (TIK MODELIS / su fizika) ir mygtukas jam
  pakeisti. Varnele "Tik modelis" 1 dalyje lieka pazymeta, kol jos nenuimi.

TURBO / KOMPRESORIUS (logic)
----------------------------
- Aplankas ">> TURBO / KOMPRESORIUS (logic)": bet kurios masinos turbinos ir
  kompresoriai (pasirink modeli 1 dalyje, pvz. bastion, etk, pickup...).
- "PRITAIKYTI TURBO / KOMPRESORIU": tavo varikliui perkeliami jo duomenys
  (slegis, wastegate, inercija, kreive) ir garsas (svilpimas, BOV, whine).
  Imama ir is jo pod-detaliu (twin turbo ijungiamas kolektoriuje).
- Donoro nustatymai (pvz. Wastegate Pressure) atsiranda iprastame Tuning meniu.
- Veikia ir ant swap'into variklio. Atsaukti: 3 dalyje "Grazinti originalu".

RADIATORIUS (ausinimas, logic)
------------------------------
- Radiatorius beveik vien duomenys (2 mazgai ir modelis, kabantis ant savo
  masinos kebulo), todel atskirai jo atspawninti negalima - perziura nematoma.
- Aplankas ">> RADIATORIUS (ausinimas, logic)": pasirink ir spausk
  "PRITAIKYTI RADIATORIU". Tavo radiatorius ir modelis lieka, varikliui
  perkeliami donoro ausinimo duomenys: plotas, efektyvumas, ausinimo skyscio
  kiekis, ventiliatorius, termostatas. Atsaukti: 3 dalyje "Grazinti originalu".
- Veikia tik varikliams, kuriems skaiciuojama temperatura (thermals).

PAKABA LOGIC (rekomenduojama) - 5 dalis lange
----------------------------------------------
Tavo pakabos geometrija ir fizika lieka (niekas nelus), keiciasi charakteris:
- Pakabu aplanke pasirink donoro pakaba ir spausk "LOGIC: perkelti tik
  charakteri" - perkeliami donoro spyruokliu, amortizatoriu ir stabilizatoriaus
  standumai (vidurkiai is jo jbeam, su numatytais kintamaisiais).
- 5 dalyje priekiui ir galui atskirai: prosvaisa (-20..+60 cm, kartu
  prailginami ir amortizatoriu eigos ribotuvai), spyruokles x, amortizatoriai x,
  stabilizatorius x (iki x6; amortizatoriai dar ribojami pagal mazgu mase -
  sunkvezimio amortizatoriai ant lengvos masinos sprogdindavo fizika). "PRITAIKYTI PAKABA" / "Atstatyti".
- Pastaba: lingines spyruokles (tiltai su lingemis) nera "bounded" spyruokles,
  joms prosvaisa / standumas gali neveikti - amortizatoriai ir stabilizatorius veikia.

PAKABOS SWAP (priekine / galine) - eksperimentinis tikras geometrijos swap
--------------------------------
1. "Modelis" - masina, IS KURIOS imsi pakaba. Aplankai
   ">> PRIEKINE PAKABA" ir ">> GALINE PAKABA".
2. "... SWAP - perziura" - nauja pakaba atsiras ten, kur yra senoji.
   Pastumk (pvz. Y - kad ratai butu arkose, Z - aukstis).
3. "ATLIKTI PAKABOS SWAP" - sena pakaba su visais savo ratais, stebulemis,
   amortizatoriais, stabdziais ir vairavimu dingsta, idedama nauja.
   Kartu "atsinesami" donoro remo taskai, prie kuriu pakaba buvo prisukta
   (amortizatoriu virsus, lingiu kabliai, vairo deze, diferencialo laikikliai)
   - jie privirinami prie tavo kebulo. Svirtys, tiltas ir amortizatoriai lieka
   judantys, vairo hydros veikia.
   Visas naujos pakabos medis gauna unikalius mazgu ir begiu vardus
   (nesusipina su kebulu) ir nesimusa su savo kebulu - todel nesprogsta.
   Senesne versija padarytam swap'ui 3 dalyje yra mygtukas "PATAISYTI".
4. Jei naujos pakabos velenai nerastu tavo masinos pavaru - automatiskai
   ijungiamos universalios pavaros (pagal 4 dalies nustatymus). Tai ypac
   svarbu LIVE AXLE (tiltams): tilto diferencialas iesko donoro kardano,
   kurio tavo masina neturi.
5. "3. Idiegtos detales": "Perkelti" / "Grazinti originalia".
- ANTRA GALINE ASIS (6 ratai): galines pakabos aplanke spausk "PRIDETI KAIP
  ANTRA GALINE ASI". Tavo galine pakaba lieka, nauja asis atsiranda uz jos ant
  savo virtualaus remo (2 dalyje pastumk Y). Jos ratai gauna savo vardus, o abi
  galines asys varomos universaliomis pavaromis (tarp ju - tarpasinis
  diferencialas; uzrakinamas su "Galinis" locker).
   Anksciau padarytam swap'ui spausk "PATAISYTI" - ijungs ir pavaras, jei reikia.
- Stabilumas: atsinesti donoro remo taskai islaiko donoro mase; jei i ta pati
  kebulo taska eina daug suvirinimu, ju standumas automatiskai sumazinamas
  pagal mazgo mase, o per lengviems mazgams pridedama mases tiek, kiek reikia
  (kitaip fizika "sprogsta" - Instability detected).
- Naujos pakabos spyruokles issitempia per 0,5 s (ne smugiu spawn'o metu).
- Donoro remo taskai ieskomi VISOSE donoro detalese (pvz. desert pakaba
  kabo ant pickup_desert_frame tasku, kuriu iprastas remas neturi). Jei kokio
  tasko nerasta, konsoleje: "donor nodes not found, rows on them dropped".
- HOOK'AI: pakabos taskai, kuriuos donoro remas PRISUKES - laiko bent 3
  paprastos sijos i 3 skirtingus remo taskus (pvz. pickup 4-link svirciu
  priekiniai galai rx1l / rx1r, amortizatoriu virsus rs2l). Tos tvirtinimo
  sijos ir ju remo taskai neatsinesami - hook'a laiko virtualus remas.
  Taskai, laikomi tik 1-2 sijomis (skersine traukle, svirtys), JUDA - ju sijos
  atsinesamos su tiksliu remo tasku, kaip donore. Taip pat atsinesamos
  "darbines" remo sijos (atsokos buferiai, ribotuvai).
- Pakabos perziura suklijuojama standziai (nebesisuka, ratai neskraido).
- VIRTUALUS REMAS (kiekvienam pakabos swap'ui): 8 sunkus nauji mazgai (deze
  aplink hook'us). Visi hook'ai ir atsinesti donoro taskai laikomi visu 8
  kampu, ir TIK sie 8 kampai privirinami prie tavo kebulo (kiekvienas prie
  ~8 kebulo tasku). Pakaba kabo ant savo remo, ne ant kebulo. Remas nematomas (tik fizika),
  pamatyti galima su Ctrl+B (sijos). Pati pakaba (be padangu) ir kebulo
  zona aplink tvirtinimo taskus NIEKADA nesilanksto ir nelusta - svetimo tilto
  svoris nebesuplesys kebulo. Senam swap'ui - "PATAISYTI".
- Naujos pakabos padangos nesimusa su savo kebulu (didesni donoro ratai
  dazniausiai lenda i arkas). Su zeme - kaip iprastai.

UNIVERSALIOS PAVAROS (4 dalis lange)
------------------------------------
Viskas, kas yra UZ pavaru dezes (kardanas, skirstymo deze, diferencialai,
pusasiai), ismetama ir sugeneruojama is naujo pagal tikras ratu vietas:
- Varomi ratai: RWD / FWD / AWD (su centriniu diferencialu ir galios
  paskirstymu priekis/galas).
- Diferencialo tipas: open / lsd / viscous / locked.
- Uzrakinami (locker): priekinis, galinis, centrinis (AWD). Toks diferencialas
  turi 2 rezimus - pasirinktas tipas ir "locked" (abi puses sukasi vienodai).
  Perjungiama vaziuojant: 4 dalyje "Perjungti vaziuojant" (Priekinis / Galinis /
  Centrinis / Visi), zaidimo klavisu "Toggle differential mode" arba zaidimo
  powertrain UI mygtukais.
- Perjungiamas 2WD / 4WD (part-time, tik AWD): vietoj centrinio diferencialo -
  skirstymo deze kaip visureigiuose: 2WD (galas) arba 4WD (priekis ir galas
  sujungti 50 / 50). Pradzioje 2WD. Ant sauso asfalto 4WD posukiuose "stringa".
- Zemoji pavara (low range): papildoma deze po pavaru deze, High (1:1) arba Low
  (santykis 1.5 - 4.5, numatyta 2.72) - letai, bet labai stipriai.
- Viska perjungi vaziuojant: 4 dalyje "Perjungti vaziuojant" - 2WD / 4WD,
  High / Low, Priekinis / Galinis / Centrinis, Visi diferencialai.
- Galutine pavara (final drive). "Nuskaityti dabartine" - paima, kokia yra dabar.
- Veikia su 3 asiu sunkvezimiais (tandem) ir dvigubais ratais (dually).
- Masinos ratu velenai (spindle) prijungiami prie nauju diferencialu.
Taip BET KOKS variklis + BET KOKIA deze + BET KOKIA masina varo ratus.
Pastaba: tai fizika, ne modelis - naujo kardano meso nesimato.

MASINOS ISSAUGOJIMAS
--------------------
- Naudok zaidimo iprasta issaugojima (Vehicle Config > Save): kartu issaugoma
  VISKAS, ka padare mod'as - detales, engine / gearbox / pakabos swap'ai,
  universalios pavaros, logic pakaba, tiuningas, saugos elektronika, spalva.
  Uzsikrauna bet kuriame map'e.
- Svarbu: Part Attacher mod'as turi buti ijungtas (be jo swap'ai neuzsikrauna).

SAUGOS ELEKTRONIKA (6 dalis lange)
----------------------------------
Pazymek, ko reikia, ir spausk "IDIEGTI / ATNAUJINTI" (masina persikrauna):
- ABS - stabdant ratai neuzsiblokuoja (visi ratai).
- Traction control (TC) - nukerta gaza / pristabdo buksuojanti rata.
- Stabilumo kontrole (ESC) - pristabdo ratus, kad masina neslystu ir nesisuktu.
  Nustatymai bendri (ne pagal konkrecia masina).
- 2-step (launch control) - startui laiko pasirinktus apsisukimus: stovint
  laikyk stabdi + pilna gaza, atleisk stabdi.
- Line lock - laiko priekinius stabdzius, galiniai ratai buksuoja (burnout).
Vaziuojant: TC / ESC rezimai (ESC + TC / TC / Off), 2-step ir line lock
ijungiami radialiniame meniu (Vehicle features) arba Options > Controls
klavisais ("Toggle ESC mode", "Toggle Two-Step", "Toggle Line Lock").
Ko masina jau turi pati (savo ESC / TC, 2-step), lieka jos - mod'as to nekeicia.

APSAUGA NUO SUDAUZYMO (nusistovejimas)
--------------------------------------
"Apsauga nuo sudauzymo pirmas 2.5 s" (ijungta pagal nutylejima): po kiekvieno
spawn'o / persikrovimo / R visos masinos sijos 2,5 s nesilanksto ir nelusta,
kol naujos detales nusistovi. Po to grazinama iprasta zalos fizika
(konsoleje: "settle time over, damage back on").

Virtualus tvirtinimas (detales su fizika)
-----------------------------------------
- Detale niekada nevirinama tiesiai prie tavo masinos tasku. Aplink ja
  sukuriami 8 lengvi remo taskai, kurie laiko kiekviena detales taska, ir tik
  jie privirinami prie masinos strukturos (chassis / frame / body, isskirstyta,
  standumas pagal tasku mase). Detale turi savo svori, sijas ir susidurimus -
  bullbar veikia kaip bullbar.
- Detales sijos ir trikampiai i donoro masinos kebula (remas, buferis) ismetami:
  jie nebegali prisikabinti prie tavo masinos tasku tokiais paciais vardais.
- Detales trikampiai, kurie atsiranda kebulo viduje, kebulo nestumia.

Nustatymai
----------
- Suvirinimo tasku: viso suvirinimu; vienam remo taskui - sis skaicius / 3.
- Maks. tarpas: kiek toli detales taskas gali buti nuo kebulo tasko (m).
  Jei rodo "Per toli" - priartink detale arba padidink si skaiciu. Remas
  privirinamas 3 kartus toliau (bent 1 m).
- Stiprumas (N): vienos suvirinimo sijos jega, nuo kurios ji nutruksta;
  lankstytis pradeda nuo puses. Numatyta 40000 (BeamNG savo buferi tvirtina
  28000 N sijomis). "Nesulauzoma" - niekada.
- Be susidurimu: detale nesimus su kitomis masinomis (tik dekoracija).
- Masinos spalva: detale nudazoma tavo masinos spalva.

Pastabos
--------
- Pritvirtinant masina persikrauna (kaip keiciant detales Parts meniu) -
  sutaisoma ir lieka toje pacioje vietoje.
- Kai kurios detales neturi savo mazgu (tik vizualios, pvz. lipdukai) -
  jas atskirai sukurti negalima, modas apie tai pranes.
- Ratu mazgai suvirinimui nenaudojami.
