import asyncio
import base64
from contextlib import asynccontextmanager
from datetime import datetime
import io
import os
import struct
import time
import wave
import webbrowser
from bleak import BleakClient, BleakScanner
import cv2
from dotenv import load_dotenv
import edge_tts
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from faster_whisper import WhisperModel
import numpy as np
from openai import OpenAI
import av
import sounddevice as sd
import soundfile as sf
import uvicorn

load_dotenv()

# ================= CONFIGURĂRI & CONSTANTE =================
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "")
COMPANION_SERVICE_UUID = "B6632277-0642-458B-A7A0-23FB1DC92C93"
RTSP_URL = os.getenv("RTSP_URL", "rtsp://192.168.43.1:554/live")
VISION_MODEL = os.getenv("VISION_MODEL", "z-ai/glm-5.3-flash")
FRONTEND_DIST_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "frontend", "dist")
FRONTEND_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "frontend")

if not OPENROUTER_API_KEY:
    print("[AVERTISMENT] OPENROUTER_API_KEY nu este setat! Setați cheia în fișierul .env pentru a folosi asistentul AI.")

# Client OpenRouter
client = OpenAI(
    base_url="https://openrouter.ai/api/v1",
    api_key=OPENROUTER_API_KEY or "not-configured",
)

# Stare Globală
state = {
    "ble_status": "Disconnected",
    "device_name": None,
    "device_mac": None,
    "rtsp_status": "Offline",
    "audio_status": "Idle",
    "last_snapshot": None,
    "battery_level": 85,
}

# Buffere și Stare Audio
pcm_audio_buffer = bytearray()
is_recording = False
last_audio_time = 0
whisper_model = None
opus_codec = None


# ================= WEBSOCKET & LOGGING MANAGER =================
class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)
        # Trimite starea curentă imediat după conectare
        await websocket.send_json({"type": "state_update", "data": state})

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def broadcast(self, payload: dict):
        for connection in list(self.active_connections):
            try:
                await connection.send_json(payload)
            except Exception:
                self.disconnect(connection)


manager = ConnectionManager()


async def log_event(message: str, level: str = "info"):
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{timestamp}] {message}")
    await manager.broadcast(
        {
            "type": "log",
            "data": {
                "timestamp": timestamp,
                "message": message,
                "level": level,
            },
        }
    )


async def update_state(key: str, value: any):
    state[key] = value
    await manager.broadcast({"type": "state_update", "data": {key: value}})


# ================= 1. SERIALIZARE PACHETE BLE ABMATE =================
def build_abmate_packet(cmd_key: int, cmd_type: int, seq_num: int, payload: bytes = b"") -> bytes:
    """Construiește pachet conform specificației Topstep ABMate"""
    header = struct.pack(">BBBBB", cmd_key, cmd_type, seq_num, 0x00, 0x01)
    return header + payload


# ================= 2. DECODARE & COLECTARE SUNET BLE =================
def ble_audio_handler(sender, data: bytearray):
    """Recepționează Opus de la ochelari prin BLE și îl decodează în PCM"""
    global pcm_audio_buffer, last_audio_time, is_recording
    if len(data) < 5 or opus_codec is None:
        return

    _, cmd_type, _, _, _ = struct.unpack(">BBBBB", data[:5])
    payload = bytes(data[5:])

    # cmdType 0x03 = Notificare audio asincronă de la microfon
    if cmd_type == 0x03 and len(payload) > 0:
        try:
            packet = av.Packet(payload)
            frames = opus_codec.decode(packet)
            for f in frames:
                pcm_chunk = f.to_ndarray().tobytes()
                pcm_audio_buffer.extend(pcm_chunk)
            last_audio_time = time.time()
            if not is_recording:
                is_recording = True
                asyncio.create_task(update_state("audio_status", "Listening"))
        except Exception:
            pass


# ================= 3. CAPTURĂ CADRU VIZUAL (ON-DEMAND) =================
async def capture_snapshot_from_glasses():
    """Extrage 1 cadru curat din fluxul RTSP pentru a salva bateria de 300mAh"""
    await log_event("📸 Capturare cadru din camera ochelarilor...")
    
    # Executăm captura OpenCV într-un thread separat pentru a nu bloca bucla asyncio
    loop = asyncio.get_running_loop()
    def _read_frame():
        cap = cv2.VideoCapture(RTSP_URL, cv2.CAP_FFMPEG)
        ret, frame = cap.read()
        cap.release()
        return ret, frame

    try:
        ret, frame = await loop.run_in_executor(None, _read_frame)
        if ret:
            _, buffer = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            b64_data = base64.b64encode(buffer).decode("utf-8")
            await update_state("rtsp_status", "Online")
            await update_state("last_snapshot", b64_data)
            return b64_data
        else:
            await update_state("rtsp_status", "Offline")
            await log_event("⚠️ Nu am putut citi cadrul RTSP. Verifică Wi-Fi-ul ochelarilor.", level="warning")
            return None
    except Exception as e:
        await update_state("rtsp_status", "Offline")
        await log_event(f"⚠️ Eroare captură RTSP: {e}", level="warning")
        return None


# ================= 4. TEXT-TO-SPEECH ÎN LIMBA ROMÂNĂ =================
async def speak_romanian_response(text: str):
    """Generează voce naturală în limba română și o redă în difuzoarele ochelarilor"""
    await update_state("audio_status", "Speaking")
    await log_event(f"🔊 Redare voce: {text}")
    try:
        tts = edge_tts.Communicate(text, voice="ro-RO-EmilNeural")
        audio_bytes = bytearray()
        async for chunk in tts.stream():
            if chunk["type"] == "audio":
                audio_bytes.extend(chunk["data"])

        # Redare asincronă non-blocantă
        loop = asyncio.get_running_loop()
        def _play():
            data, fs = sf.read(io.BytesIO(audio_bytes))
            sd.play(data, fs)
            sd.wait()

        await loop.run_in_executor(None, _play)
    except Exception as e:
        await log_event(f"❌ Eroare la redarea audio: {e}", level="error")
    finally:
        await update_state("audio_status", "Idle")


# ================= 5. APEL OPENROUTER CU GLM-5.3-FLASH =================
async def process_user_query(user_text: str):
    """Trimite imaginea + întrebarea transcrisă la GLM-5.3-Flash"""
    await update_state("audio_status", "Processing")
    base64_image = await capture_snapshot_from_glasses()

    # Emite mesajul utilizatorului în UI
    await manager.broadcast(
        {
            "type": "conversation",
            "data": {
                "role": "user",
                "text": user_text,
                "timestamp": datetime.now().strftime("%H:%M:%S"),
                "image": base64_image,
            },
        }
    )

    user_content = [
        {
            "type": "text",
            "text": (
                f"Întrebare utilizator: {user_text}\n"
                "Instrucțiuni de sistem: Ești asistentul integrat în ochelarii smart MT5 Ultra. "
                "Ai în față poza capturată de camera ochelarilor. Răspunde direct, concis, "
                "natural și scurt în limba română (maxim 2-3 propoziții clare)."
            ),
        }
    ]

    if base64_image:
        user_content.append(
            {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{base64_image}"}}
        )

    await log_event(f"🧠 Interogare model OpenRouter [{VISION_MODEL}]...")

    loop = asyncio.get_running_loop()
    try:
        def _call_openrouter():
            return client.chat.completions.create(
                model=VISION_MODEL,
                messages=[{"role": "user", "content": user_content}],
                temperature=0.4,
            )

        response = await loop.run_in_executor(None, _call_openrouter)
        ai_answer = response.choices[0].message.content
        await log_event(f"🤖 RĂSPUNS AI: {ai_answer}")

        # Emite răspunsul AI către UI
        await manager.broadcast(
            {
                "type": "conversation",
                "data": {
                    "role": "assistant",
                    "text": ai_answer,
                    "timestamp": datetime.now().strftime("%H:%M:%S"),
                },
            }
        )

        # Redă răspunsul vocal în ochelari
        await speak_romanian_response(ai_answer)

    except Exception as e:
        await log_event(f"❌ Eroare la apelul OpenRouter: {e}", level="error")
        await update_state("audio_status", "Idle")


# ================= 6. DETECȚIE VOCE & TRIGGER AUTOMAT (VAD) =================
async def audio_processing_loop():
    """Detectează când utilizatorul s-a oprit din vorbit (pauză de 1 secundă)"""
    global pcm_audio_buffer, is_recording, last_audio_time

    while True:
        await asyncio.sleep(0.2)
        # Dacă a vorbit și s-a așternut liniștea mai mult de 1 secundă
        if is_recording and (time.time() - last_audio_time > 1.0) and len(pcm_audio_buffer) > 16000:
            await log_event("🎙️ Voce detectată. Transcriere Whisper în curs...")
            is_recording = False
            raw_pcm = bytes(pcm_audio_buffer)
            pcm_audio_buffer.clear()

            # Conversie buffer PCM -> WAV în memorie
            wav_io = io.BytesIO()
            with wave.open(wav_io, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(16000)
                wf.writeframes(raw_pcm)
            wav_io.seek(0)

            loop = asyncio.get_running_loop()
            def _transcribe():
                segments, _ = whisper_model.transcribe(wav_io, language="ro")
                return " ".join([s.text for s in segments]).strip()

            user_transcript = await loop.run_in_executor(None, _transcribe)

            if len(user_transcript) > 2:
                await log_event(f"👤 Utilizator a spus: \"{user_transcript}\"")
                await process_user_query(user_transcript)
            else:
                await update_state("audio_status", "Idle")
                await log_event("⚠️ Zgomot ambiental ignorat.")


# ================= 7. SCANARE & LOGICĂ BLE CONTINUĂ =================
async def run_ble_service():
    """Căutare și menținere conexiune BLE cu ochelarii MT5 Ultra"""
    global opus_codec, whisper_model

    await log_event("⏳ Se inițializează decodorul Opus & Whisper STT...")
    opus_codec = av.CodecContext.create('opus', 'r')
    opus_codec.sample_rate = 16000
    opus_codec.channels = 1
    whisper_model = WhisperModel("tiny", device="cpu", compute_type="int8")
    await log_event("✅ Whisper STT pregătit.")

    while True:
        try:
            await update_state("ble_status", "Scanning")
            await log_event("🔍 Căutare ochelari MT5 Ultra prin Bluetooth BLE...")

            target_device = None
            devices = await BleakScanner.discover(timeout=5.0)

            for d in devices:
                mfg_data = d.metadata.get("manufacturer_data", {})
                for mfg_id, raw_bytes in mfg_data.items():
                    if len(raw_bytes) >= 11:
                        decoded_mac = ":".join([f"{(b ^ 0xAD):02X}" for b in raw_bytes[5:11]])
                        await log_event(f"🎯 Găsit dispozitiv compatibil -> MAC: {decoded_mac} ({d.name})")
                        target_device = d
                        await update_state("device_mac", decoded_mac)
                        await update_state("device_name", d.name or "MT5 Ultra")
                        break
                if target_device:
                    break

            if not target_device:
                await update_state("ble_status", "Disconnected")
                await log_event("⏳ Ochelarii nu au fost găsiți. Reîncercare în 4 secunde...")
                await asyncio.sleep(4)
                continue

            await update_state("ble_status", "Connecting")
            await log_event(f"🔗 Conectare la {target_device.name} ({target_device.address})...")

            async with BleakClient(target_device) as ble_client:
                await update_state("ble_status", "Connected")
                await log_event(f"✅ Conectat cu succes prin BLE la {target_device.name}!")

                service = ble_client.services.get_service(COMPANION_SERVICE_UUID)
                if not service:
                    await log_event("⚠️ Serviciul BLE ABMate nu a fost găsit pe dispozitiv.", level="error")
                    continue

                write_char = None
                notify_char = None

                for char in service.characteristics:
                    if "write" in char.properties or "write-without-response" in char.properties:
                        write_char = char
                    if "notify" in char.properties:
                        notify_char = char

                if notify_char:
                    await ble_client.start_notify(notify_char, ble_audio_handler)
                    await log_event("📡 Ascultare notificări audio Opus activată.")

                if write_char:
                    # 1. Hotspot AP
                    hotspot_cmd = build_abmate_packet(cmd_key=0x10, cmd_type=0x01, seq_num=1, payload=b"\x00")
                    await ble_client.write_gatt_char(write_char, hotspot_cmd)
                    await log_event("📡 Comandă trimisă: Activare Wi-Fi Hotspot AP.")

                    # 2. RTSP Stream
                    stream_cmd = build_abmate_packet(cmd_key=0x12, cmd_type=0x01, seq_num=2, payload=b"\x01")
                    await ble_client.write_gatt_char(write_char, stream_cmd)
                    await log_event("📹 Comandă trimisă: Activare server RTSP cameră.")

                    # 3. Microfon AI
                    audio_cmd = build_abmate_packet(cmd_key=0x14, cmd_type=0x01, seq_num=3, payload=b"\x00")
                    await ble_client.write_gatt_char(write_char, audio_cmd)
                    await log_event("🎙️ Microfon AI activat. Sistemul ascultă!")

                # Rulare buclă audio în timp ce BLE este conectat
                audio_task = asyncio.create_task(audio_processing_loop())

                while ble_client.is_connected:
                    await asyncio.sleep(1)

                audio_task.cancel()
                await update_state("ble_status", "Disconnected")
                await log_event("🔌 Conexiunea BLE a fost întreruptă.", level="warning")

        except Exception as e:
            await update_state("ble_status", "Disconnected")
            await log_event(f"⚠️ Eroare conexiune BLE: {e}", level="error")
            await asyncio.sleep(4)


# ================= 8. FASTAPI WEB SERVER =================
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Pornire background task BLE
    ble_task = asyncio.create_task(run_ble_service())

    # Pornire server frontend Vite (npm run dev)
    frontend_process = None
    if os.path.exists(FRONTEND_DIR):
        try:
            frontend_process = await asyncio.create_subprocess_shell(
                "npm run dev", cwd=FRONTEND_DIR
            )
            confirmation_msg = (
                "\n" + "=" * 55 + "\n"
                "🚀 Localhost Web UI started successfully!\n"
                "👉 Frontend UI:   http://localhost:3000\n"
                "👉 Backend & WS:  http://localhost:8000\n"
                + "=" * 55 + "\n"
            )
            print(confirmation_msg)
            await log_event("🚀 Localhost Web UI pornit: http://localhost:3000")
        except Exception as e:
            await log_event(f"⚠️ Nu s-a putut porni 'npm run dev': {e}", level="warning")

    # Deschide automat interfața web în browser
    async def _open_browser():
        await asyncio.sleep(2.0)
        webbrowser.open("http://localhost:3000")

    asyncio.create_task(_open_browser())
    yield
    # Oprire procese de fundal la shutdown
    ble_task.cancel()
    if frontend_process:
        try:
            frontend_process.terminate()
            await frontend_process.wait()
        except Exception:
            pass


app = FastAPI(title="MT5 Ultra Smart Glasses API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/status")
async def get_status():
    return state


@app.post("/api/snapshot/trigger")
async def trigger_snapshot():
    snapshot = await capture_snapshot_from_glasses()
    return {"status": "success", "snapshot": snapshot is not None}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    try:
        while True:
            # Păstrează conexiunea deschisă și ascultă eventuale comenzi din UI
            data = await websocket.receive_json()
            if data.get("action") == "trigger_snapshot":
                await capture_snapshot_from_glasses()
            elif data.get("action") == "ask_text":
                prompt = data.get("prompt", "")
                if prompt:
                    asyncio.create_task(process_user_query(prompt))
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception:
        manager.disconnect(websocket)


# ================= 9. SERVIRE FRONTEND =================
if os.path.exists(FRONTEND_DIST_DIR):
    assets_dir = os.path.join(FRONTEND_DIST_DIR, "assets")
    if os.path.exists(assets_dir):
        app.mount("/assets", StaticFiles(directory=assets_dir), name="assets")

    @app.get("/{full_path:path}")
    async def serve_frontend(full_path: str):
        file_path = os.path.join(FRONTEND_DIST_DIR, full_path)
        if full_path and os.path.exists(file_path) and os.path.isfile(file_path):
            return FileResponse(file_path)
        return FileResponse(os.path.join(FRONTEND_DIST_DIR, "index.html"))


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
