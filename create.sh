#!/bin/bash
set -e

echo ">>> Creating VNC-Docker from scratch..."

# 1. Directories
mkdir -p nginx certs audio novnc

# 3. Generate VNC password (you can change it later)
if [ ! -f certs/passwd ]; then
    echo ">>> Creating VNC password file (default password: password)..."
    x11vnc -storepasswd password certs/passwd
fi

# 4. Generate self-signed SSL cert (valid 10 years)
if [ ! -f certs/novnc.pem ]; then
    echo ">>> Generating self-signed SSL certificate..."
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout certs/novnc.key -out certs/novnc.crt \
        -days 3650 -subj "/CN=localhost"
    cat certs/novnc.key certs/novnc.crt > certs/novnc.pem
    chmod 600 certs/novnc.key certs/novnc.pem
fi

# 5. Download noVNC
if [ ! -f novnc/vnc.html ]; then
    echo ">>> Downloading noVNC..."
    git clone --depth 1 https://github.com/novnc/noVNC.git novnc-tmp
    cp -r novnc-tmp/* novnc/
    rm -rf novnc-tmp
fi

# 6. Write the hardened nginx config
cat > nginx/nginx.conf << 'EOF'
worker_processes auto;
events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    server {
        listen 443 ssl;
        server_name _;

        ssl_certificate     /certs/novnc.pem;
        ssl_certificate_key /certs/novnc.pem;

        # Static noVNC files
        location / {
            root /usr/share/nginx/html;
            try_files $uri $uri/ /vnc.html;
        }

                # VNC WebSocket (now going to host-network websockify)
        location /websockify {
            proxy_pass http://127.0.0.1:5902;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_buffering off;
        }

        # Audio WebSocket (still on Docker network)
        location /audio-ws {
            proxy_pass http://127.0.0.1:5903;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_set_header Host $host;
            proxy_read_timeout 3600s;
            proxy_buffering off;
        }
    }
}
EOF

# 7. Audio Dockerfile (no external ffmpeg image)
cat > audio/Dockerfile << 'EOF'
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libpulse0 \
        pulseaudio-utils \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -u 1000 -m -s /bin/bash pulseuser || true
USER 1000
WORKDIR /home/pulseuser
ENTRYPOINT ["ffmpeg"]
EOF

# 8. Create start.sh
cat > start.sh << 'EOF'
#!/bin/bash
export UID=$(id -u)
export GID=$(id -g)

# Optional: regenerate cert every start (uncomment if you want)
# openssl req -x509 -nodes -newkey rsa:2048 \
#   -keyout certs/novnc.key -out certs/novnc.crt \
#   -days 3650 -subj "/CN=localhost"
# cat certs/novnc.key certs/novnc.crt > certs/novnc.pem

docker compose up -d --build
x11vnc -localhost -norepeat 0 -noxdamage -forever -rfbport 5901 -rfbauth ./certs/passwd &
echo ">>> Everything is up. Open https://YOUR-IP/"
EOF

# 9. Create stop.sh
cat > stop.sh << 'EOF'
#!/bin/bash
docker compose down
killall x11vnc
echo ">>> Everything stopped."
EOF


# 10. Create docker-compose.yaml
cat > docker-compose.yaml << 'EOF'
services:
  nginx:
    image: nginx:alpine
    container_name: novnc-nginx
    network_mode: host
    ports:
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/certs:ro
      - ./novnc:/usr/share/nginx/html:ro
    depends_on:
      - websockify
      - audio-ws
    restart: unless-stopped

  websockify:
    image: jwnmulder/websockify:latest
    container_name: novnc-websockify
    network_mode: host
    command: ["127.0.0.1:5902", "127.0.0.1:5901"]
    restart: unless-stopped

  audio:
    build: ./audio
    container_name: novnc-audio
    network_mode: host
    user: "${UID:-1000}:${GID:-1000}"
    environment:
      - PULSE_SERVER=unix:/run/user/${UID:-1000}/pulse/native
      - PULSE_COOKIE=/run/user/${UID:-1000}/pulse/cookie
    volumes:
      - /run/user/${UID:-1000}/pulse:/run/user/${UID:-1000}/pulse:ro
    entrypoint: ["sh", "-c"]
    command:
      - |
        ffmpeg -f pulse -i "$(pactl get-default-sink).monitor" \
          -acodec libopus -b:a 64k -ar 48000 -ac 2 \
          -application lowdelay -frame_duration 10 \
          -f webm -cluster_size_limit 1k -cluster_time_limit 10 \
          -listen 1 tcp://127.0.0.1:5904
    restart: unless-stopped

  audio-ws:
    image: jwnmulder/websockify:latest
    container_name: novnc-audio-ws
    network_mode: host
    command: ["127.0.0.1:5903", "127.0.0.1:5904"]
    depends_on:
      - audio
    restart: unless-stopped
EOF

# 11. Edit vnc.html to include the audio portion
cat >> audio_inject.html << 'EOF'
<div style="position: fixed; bottom: 15px; right: 15px; z-index: 9999;
            background: #2c3e50; padding: 10px 14px; border-radius: 8px;
            border: 1px solid #34495e; box-shadow: 0 4px 6px rgba(0,0,0,0.3);
            font-family: sans-serif; color: #fff; font-size: 13px;
            display: flex; align-items: center; gap: 12px;">
    <span style="font-weight: bold;">System Audio:</span>
    <button id="audio-toggle" style="padding: 4px 12px; border-radius: 4px;
            border: none; background: #27ae60; color: white; cursor: pointer;">
        Start Audio
    </button>
    <span id="audio-status" style="opacity: 0.7;">stopped</span>
</div>

<script>
(function () {
    const WS_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://')
                 + location.host + '/audio-ws';

    let ws = null;
    let mediaSource = null;
    let sourceBuffer = null;
    let audio = null;
    let queue = [];
    let isPlaying = false;

    const toggleBtn = document.getElementById('audio-toggle');
    const statusEl  = document.getElementById('audio-status');

    function setStatus(text, color = '#fff') {
        statusEl.textContent = text;
        statusEl.style.color = color;
    }

    function startAudio() {
        if (isPlaying) return;

        audio = new Audio();
        audio.autoplay = true;
        document.body.appendChild(audio);

        mediaSource = new MediaSource();
        audio.src = URL.createObjectURL(mediaSource);

        mediaSource.addEventListener('sourceopen', () => {
            try {
                sourceBuffer = mediaSource.addSourceBuffer('audio/webm; codecs="opus"');
                sourceBuffer.mode = 'sequence';
            } catch (e) {
                setStatus('codec unsupported', '#e74c3c');
                console.error(e);
                return;
            }

            sourceBuffer.addEventListener('updateend', () => {
                // Keep only the last ~1.5 seconds of buffer
                if (audio.buffered.length > 0) {
                    const current = audio.currentTime;
                    const start = audio.buffered.start(0);
                    if (current - start > 1.5) {
                        try {
                            sourceBuffer.remove(0, current - 0.8);
                        } catch (err) {}
                    }
                }

                if (queue.length > 0 && !sourceBuffer.updating) {
                    sourceBuffer.appendBuffer(queue.shift());
                }
            });

            ws = new WebSocket(WS_URL);
            ws.binaryType = 'arraybuffer';

            ws.onopen = () => {
                setStatus('live', '#2ecc71');
                toggleBtn.textContent = 'Stop Audio';
                toggleBtn.style.background = '#c0392b';
                isPlaying = true;
            };

            ws.onmessage = (e) => {
                if (!sourceBuffer) return;
                if (sourceBuffer.updating || queue.length > 0) {
                    queue.push(e.data);
                } else {
                    try {
                        sourceBuffer.appendBuffer(e.data);
                    } catch (err) {
                        queue.push(e.data);
                    }
                }
            };

            ws.onclose = () => {
                setStatus('disconnected', '#e74c3c');
                stopAudio(false);
            };

            ws.onerror = (err) => {
                console.error(err);
                setStatus('error', '#e74c3c');
            };
        });
    }

    function stopAudio(closeWs = true) {
        isPlaying = false;
        toggleBtn.textContent = 'Start Audio';
        toggleBtn.style.background = '#27ae60';
        setStatus('stopped');

        if (ws && closeWs) {
            try { ws.close(); } catch(e) {}
            ws = null;
        }
        if (audio) {
            try { audio.pause(); audio.remove(); } catch(e) {}
            audio = null;
        }
        mediaSource = null;
        sourceBuffer = null;
        queue = [];
    }

    toggleBtn.addEventListener('click', () => {
        if (isPlaying) stopAudio();
        else startAudio();
    });

    // Auto-start when clicking Connect
    document.getElementById('noVNC_connect_button')?.addEventListener('click', () => {
        setTimeout(() => {
            if (!isPlaying) startAudio();
        }, 800);
    });
})();
</script>
EOF

# Insert right before </body>
sed -i '/<\/body>/e cat audio_inject.html' novnc/vnc.html
rm -f audio_inject.html


ln -rs novnc/vnc.html novnc/index.html
chmod +x start.sh stop.sh
chmod -x create.sh
echo ""
echo ">>> create.sh finished!"
echo ">>> Next steps:"
echo ">>> Change the vnc password by running  'x11vnc -storepasswd [YOUR PASSWORD] certs/passwd'"
echo ">>> ./start.sh"
