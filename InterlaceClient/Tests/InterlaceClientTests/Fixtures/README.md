Fixtures follow the return dictionaries in `backend/app.py`, `Aria2._fmt` in
`backend/aria2_client.py`, and `Kodi.now_playing` in `backend/kodi_client.py`.
Values are representative contract examples, not recordings from a live server.

`ok.json` covers health, download controls, library deletion, local playback, and
player controls. `player-inactive.json` covers the short inactive response;
`player-empty-streams.json` covers Kodi's empty current-stream objects and
nullable application properties. Library directories omit size and thumbnail.
The error fixtures represent FastAPI HTTPException and request validation bodies.
