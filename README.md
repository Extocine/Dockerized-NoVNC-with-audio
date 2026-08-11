# Dockerized-NoVNC-with-audio 🌎💻

## Overview 📝:

A lil project of mine to make a remote-access workflow utilizing:
- Docker:  To minimize dependencies and system configuration.
- Websockify: To interact with ffmpeg and x11vnc
- ffmpeg: For the audio stream
- noVNC: For accessing any X11 system remotely, using a browser-based client to avoid having to install separate software on the client's machine.

Docker is used to:
- Run nginx as the reverse proxy, and ensures the only 'public' service is nginx itself on port 443. The actual HTML files is pulled from [noVNC](https://github.com/novnc/noVNC.git) upon running `create.sh` 
- Run two instances of websockify, one to interact with `x11vnc` <sub>*(port 5902)*</sub>, and one to interact with `ffmpeg` <sub>*(port 5903)*</sub>
- Run the `ffmpeg` audio stream on port 5903

---
## Installation:
For dependencies, all that's needed is `docker-compose` `pulseaudio` and `x11vnc`
simply run 
```bash
git clone https://github.com/Extocine/Dockerized-NoVNC-with-audio
cd Dockerized-NoVNC-with-audio
chmod +x create.sh
./create.sh
```
or download the repository, naviage to the folder, and run `chmod +x create.sh && ./create.sh`

---
## Running:
To start, just naviate to the folder and run `./start.sh`

To stop, just run `./stop.sh`

---
## Known Quirks 🪲:

- The SSL Certificates generated *are* self-signed, so expect a warning from the browser. Everything is still secure and encrypted, but since there is no trusted authority doing the cert, it gives a warning
~~-  The audio stream outputs whatever the *input* of the host system is *(It plays your microphone)*, so you might want to set your input to the 'Monitor' of your default output. An easy to use GUI program to do this is `pavucontrol`.~~
-  This project is partially vibe-coded, so take that for what its worth xD
