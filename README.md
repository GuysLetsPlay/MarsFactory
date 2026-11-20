# Mars Factory

Ein Multiplayer-Fabrikbauspiel auf dem Mars. Aktueller Prototyp: First-Person-Bewegung, Netzwerk-Lobby, Marslandschaft und erste Platzier- und Abbau-Interaktionen.

## Steuerung
- WASD: laufen
- Maus: umsehen
- Leertaste: springen
- E: anvisierten Erzstein abbauen
- B: Förderbandmodus ein/aus
- Linksklick: Bandsegment platzieren
- ESC: Maus freigeben

## Multiplayer
Im Spiel „Sitzung hosten“ drücken oder die IP des Hosts eingeben. Aktuell werden Spielerbewegungen synchronisiert. Ressourcen und gebaute Bänder sind noch nicht netzwerkweit synchronisiert; diese Systeme brauchen serverautoritatives Speichern, damit alle Clients denselben Fabrikzustand sehen.

## Entwickeln
Projekt mit Godot 4.7 oder neuer öffnen: `project.godot`.
