#!/usr/bin/env python3
"""
Modular Local Diagnostic & Testing Rig for MT5 Ultra Smart Glasses (Python / Windows)

Interactive CLI that isolates and debugs each subsystem:
    [1] BLE Scan & Dissect Advertisement (Show XOR MAC)
    [2] Connect BLE & Subscribe to Notifications
    [3] Trigger Hotspot AP Mode (cmdKey 0x10)
    [4] Start RTSP Video & Capture Test Snapshot
    [5] Start Audio Recording Test (10s capture to WAV)
    [6] Full E2E Test (Snapshot -> OpenRouter GLM-5.3 -> Romanian TTS)
    [7] Read Battery & Device Info (cmdKey 0x02)
    [0] Exit

Requires: pip install bleak opencv-python requests numpy
Optional: edge-tts (for Romanian TTS), opuslib (for Opus decoding)
"""

import asyncio
import base64
import json
import os
import queue
import struct
import subprocess
import sys
import tempfile
import time
import traceback
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

# ----------------------------------------------------------------------
# BLE Scanner & MAC Unmasker
# ----------------------------------------------------------------------

KNOWN_MANUFACTURER_IDS = {
    0x5442,
    0x5444,
    0x545A,
    0x4854,
    0x5851,
    0x5A52,
    0x5A47,
    0x0600,
    0x5452,
    0xC001,
    0x5A43,
    0x4206,
    0x5A4D,
}


def extract_mac_from_manufacturer_data(man_data: bytes) -> Optional[str]:
    """Extract MAC using current rule: MAC[i] = ManufacturerData[5+i] XOR 0xAD, i=0..5."""
    if not man_data or len(man_data) < 11:
        return None
    try:
        mac_bytes = bytes(man_data[5 + i] ^ 0xAD for i in range(6))
        return ":".join(f"{b:02X}" for b in mac_bytes)
    except Exception:
        return None


class BleScanner:
    """Interactive BLE scanner using bleak."""

    def __init__(self):
        self.devices: List[Tuple[str, Optional[str], Optional[Dict[int, bytes]], int]] = []

    async def scan(self, timeout: float = 8.0) -> List[Dict[str, Any]]:
        from bleak import BleakScanner, BLEDevice, AdvertisementData

        self.devices = []
        found = {}

        def callback(device: "BLEDevice", adv: "AdvertisementData"):
            name = device.name or adv.local_name or "Unnamed"
            man = adv.manufacturer_data or {}
            found[device.address] = (name, man, device.rssi if hasattr(device,"rssi") else None)

        scanner = BleakScanner(callback, timeout=timeout)
        await scanner.start()
        await asyncio.sleep(timeout)
        await scanner.stop()

        for addr,(name, man, rssi) in found.items():
            mac = None
            for mid, data in man.items():
                if mid in KNOWN_MANUFACTURER_IDS:
                    mac = extract_mac_from_manufacturer_data(data)
                    break
            if mac is None:
                # also try any data blob that looks like ABMate
                for _, data in man.items():
                    mac = extract_mac_from_manufacturer_data(data)
                    if mac:
                        break
            if mac or any(k in name.upper() for k in ("MT5", "GLASSES", "ABMATE")):
                self.devices.append((addr, name, mac, rssi))
        return [
            {"index": i, "address": addr, "name": name, "mac": mac, "rssi": rssi}
            for i,(addr,name,mac,rssi) in enumerate(self.devices)
        ]

    async def interactive_scan(self):
        print("\n--- Scanning for MT ULTRA / Glasses devices ---")
        devices = await self.scan()
        if not devices:
            print("No matching device found.")
            return None
        for d in devices:
            print(f"  [{d['index']}] {d['name']}  addr={d['address']}  MAC={d['mac'] or 'n/a'}  RSSI={d['rssi']}")
        idx = int(input("Select index to connect (or -1 to abort): "))
        if idx < 0 or idx >= len(devices):
            return None
        return devices[idx]


# ----------------------------------------------------------------------
# ABMate Protocol IO Controller
# ----------------------------------------------------------------------

SERVICE_UUID = "B6632277-0642-458B-A7A0-23FB1DC92C93"
WRITE_CHAR_UUID = "B6632278-0642-458B-A7A0-23FB1DC92C93"
NOTIFY_CHAR_UUID = "B6632279-0642-458B-A7A0-23FB1DC92C93"


def build_abmate_packet(cmd_key: int, cmd_type: int = 0x01, payload: bytes = b"", seq_num: int = 0) -> bytearray:
    """Build ABMate packet:
        [cmdKey (1B), cmdType (1B), seqNum (1B), frameSeqNum (1B), totalFrames (1B), payload]
    """
    frame_seq = 0
    total_frames = 1
    return bytearray([cmd_key & 0xFF, cmd_type & 0xFF, seq_num & 0xFF,
                      frame_seq & 0xFF, total_frames & 0xFF]) + bytearray(payload)


class ABMateIO:
    """Connect to AIBudS-compatible peripheral and send/receive ABMate packets."""

    def __init__(self, address: str):
        from bleak import BleakClient
        self.address = address
        self.client: Optional["BleakClient"] = None
        self.notification_queue: queue.Queue[str] = queue.Queue()
        self.battery_level = 0
        self.hotspot_ssid = ""
        self.rtsp_status = ""
        self.audio_packets: List[bytes] = []
        self.seq_num: int = 0
        self.write_char = None
        self.write_no_resp_char = None
        self.cmd_char = None
        self.notify_char = None
        self.all_write_chars: List[Any] = []

    async def connect(self):
        from bleak import BleakClient
        self.client = BleakClient(self.address, timeout=15.0)
        await self.client.connect()
        print(f"\n[+] Connected to {self.address}")

        print("\n--- Discovered GATT Services & Characteristics ---")
        target_write_char = None
        target_notify_char = None
        fallback_write_char = None
        fallback_notify_char = None

        STANDARD_SERVICES = {"1800", "1801", "180a"}
        self.all_write_chars = []

        for srv in self.client.services:
            srv_uuid_short = srv.uuid.lower().split("-")[0].lstrip("0")
            is_standard = srv_uuid_short in STANDARD_SERVICES or srv.uuid.lower().startswith("0000180")
            print(f"\n[Service] {srv.uuid} ({srv.description})")

            for ch in srv.characteristics:
                props = ", ".join(ch.properties)
                print(f"   └── [Char] {ch.uuid} | Props: [{props}]")

                ch_uuid_str = ch.uuid.lower()
                if "write" in ch.properties or "write-without-response" in ch.properties:
                    if not is_standard and ch not in self.all_write_chars:
                        self.all_write_chars.append(ch)

                if ch_uuid_str == WRITE_CHAR_UUID.lower() or "ff16" in ch_uuid_str:
                    target_write_char = ch
                elif "ff17" in ch_uuid_str:
                    self.write_no_resp_char = ch
                elif "ff20" in ch_uuid_str:
                    self.cmd_char = ch
                elif ("write-without-response" in ch.properties) and not is_standard:
                    if self.write_no_resp_char is None:
                        self.write_no_resp_char = ch

                if ch_uuid_str == NOTIFY_CHAR_UUID.lower() or "ff18" in ch_uuid_str:
                    target_notify_char = ch
                elif not is_standard and fallback_notify_char is None and any(p in ch.properties for p in ("notify", "indicate")):
                    fallback_notify_char = ch

                if not is_standard and fallback_write_char is None and "write" in ch.properties:
                    fallback_write_char = ch

        self.write_char = target_write_char or fallback_write_char or self.write_no_resp_char
        self.notify_char = target_notify_char or fallback_notify_char

        if self.write_char is None and self.write_no_resp_char is None:
            raise RuntimeError("No writable characteristic found on device.")
        if self.notify_char is None:
            raise RuntimeError("No notifiable characteristic found on device.")

        print("\n--- Selected Characteristics ---")
        if self.write_char:
            print(f"[*] Primary Write (0xFF16/Write) : {self.write_char.uuid} ({', '.join(self.write_char.properties)})")
        if self.write_no_resp_char:
            print(f"[*] Fast Write (0xFF17/NoResp)   : {self.write_no_resp_char.uuid} ({', '.join(self.write_no_resp_char.properties)})")
        if self.cmd_char:
            print(f"[*] Command Write (0xFF20)       : {self.cmd_char.uuid} ({', '.join(self.cmd_char.properties)})")
        print(f"[*] Notify Char (0xFF18)         : {self.notify_char.uuid} ({', '.join(self.notify_char.properties)})")

        await self.client.start_notify(self.notify_char, self._on_notify)
        print("[+] Successfully subscribed to notifications!\n")

    def _on_notify(self, characteristic, data: bytearray):
        raw_hex = bytes(data).hex().upper()
        formatted_hex = " ".join(f"{b:02X}" for b in data)
        print(f"\n[🔔 RX RAW] <{characteristic.uuid}> len={len(data)} | HEX: {formatted_hex}", flush=True)

        if len(data) < 5:
            print(f"[!] Warning: Packet shorter than ABMate header (len={len(data)})", flush=True)
            return

        cmd_key = data[0]
        cmd_type = data[1]
        seq = data[2]
        frame_seq = data[3]
        total_frames = data[4]
        payload = bytes(data[5:])
        payload_hex = " ".join(f"{b:02X}" for b in payload)

        print(f"[📥 RX PARSED] cmdKey=0x{cmd_key:02X} cmdType=0x{cmd_type:02X} seq={seq} (frame {frame_seq}/{total_frames}) payload=[{payload_hex}]", flush=True)

        if cmd_key == 0x10:
            ssid = payload.decode("utf-8", errors="ignore").strip("\x00 \r\n\t")
            self.hotspot_ssid = ssid
            print(f"[🔥 Hotspot AP] Response received! SSID payload: '{ssid}' (HEX: {payload_hex})", flush=True)
            self.notification_queue.put(f"Hotspot SSID: {ssid if ssid else payload_hex}")
        elif cmd_key == 0x12:
            self.rtsp_status = "RTSP started"
            print(f"[📹 RTSP] Stream status response received (payload: {payload_hex})", flush=True)
            self.notification_queue.put("RTSP stream ready")
        elif cmd_key == 0x14:
            self.audio_packets.append(payload)
            print(f"[🎙️ Audio] Received Opus frame ({len(payload)} bytes)", flush=True)
        elif cmd_key == 0x02:
            # Battery parsing: handles raw [level], [component, level, state], or TLV [tag, len, level]
            if len(payload) >= 3:
                # Format: [component, level, chargingState] or TLV
                self.battery_level = payload[1] if payload[1] <= 100 else payload[0]
            elif len(payload) >= 1:
                self.battery_level = payload[0]
            print(f"[🔋 Battery] Parsed level: {self.battery_level}% (Raw payload: {payload_hex})", flush=True)
            self.notification_queue.put(f"Battery: {self.battery_level}%")

    async def write_command(self, cmd_key: int, payload: bytes = b"", cmd_type: int = 0x01, prefer_no_resp: bool = False):
        if not self.client or not self.client.is_connected:
            print("[-] Not connected to device")
            return

        self.seq_num = (self.seq_num + 1) & 0xFF
        packet = build_abmate_packet(cmd_key, cmd_type, payload, seq_num=self.seq_num)
        formatted_tx_hex = " ".join(f"{b:02X}" for b in packet)

        target_char = self.write_no_resp_char if prefer_no_resp and self.write_no_resp_char else (self.write_char or self.write_no_resp_char)
        with_response = "write" in target_char.properties if target_char else False

        print(f"[📤 TX CMD] cmdKey=0x{cmd_key:02X} -> Char: {target_char.uuid} | Mode: {'WithResponse' if with_response else 'NoResponse'} | Packet: [{formatted_tx_hex}]", flush=True)

        try:
            await self.client.write_gatt_char(target_char, packet, response=with_response)
        except Exception as e:
            print(f"[⚠️ TX Error on {target_char.uuid}]: {e}. Attempting fallback write without response...", flush=True)
            fallback_char = self.write_no_resp_char or self.cmd_char or target_char
            if fallback_char:
                print(f"[📤 TX Fallback] -> Char: {fallback_char.uuid} | Mode: NoResponse", flush=True)
                try:
                    await self.client.write_gatt_char(fallback_char, packet, response=False)
                except Exception as e2:
                    print(f"[❌ TX Fallback Failed]: {e2}", flush=True)

    async def request_hotspot_ap(self):
        # AIBuds Foundation Hotspot AP: cmdKey=0x10, cmdType=0x01
        # Payload 0x00 (AP mode trigger) and TLV fallback 0x01 0x01 0x01 (Field 1: Mode, Len 1, Val 1)
        await self.write_command(cmd_key=0x10, payload=bytes([0x00]))
        # Also send on 0xFF17 / no_resp as redundancy for chipsets requiring fast-write
        if self.write_no_resp_char:
            await self.write_command(cmd_key=0x10, payload=bytes([0x01]), prefer_no_resp=True)

    async def request_rtsp(self):
        await self.write_command(cmd_key=0x12, payload=bytes([0x01]))

    async def request_mic(self):
        await self.write_command(cmd_key=0x14, payload=bytes([0x00]))

    async def request_battery(self):
        await self.write_command(cmd_key=0x02)

    async def disconnect(self):
        if self.client and self.client.is_connected:
            await self.client.disconnect()


# ----------------------------------------------------------------------
# RTSP Frame Grabber
# ----------------------------------------------------------------------

def capture_frame(url: str = "rtsp://192.168.43.1:554/live",
                  output_path: str = "debug_snapshot.jpg",
                  timeout_ms: int = 5000) -> Dict[str, Any]:
    """Grab a single frame from RTSP stream using OpenCV."""
    import cv2

    cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG)
    if not cap.isOpened():
        return {"success": False, "error": "Could not open RTSP stream"}

    # Force TCP transport to avoid UDP packet loss on Windows
    cap.set(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, timeout_ms)
    cap.set(cv2.CAP_PROP_READ_TIMEOUT_MSEC, timeout_ms)
    cap.set(cv2.CAP_PROP_BUFFERSIZE, 0)

    ret, frame = cap.read()
    if not ret:
        cap.release()
        return {"success": False, "error": "No frame received"}

    height, width = frame.shape[:2]
    cv2.imwrite(output_path, frame)
    cap.release()

    size_bytes = os.path.getsize(output_path)
    return {
        "success": True,
        "path": output_path,
        "width": width,
        "height": height,
        "size_bytes": size_bytes,
    }


# ----------------------------------------------------------------------
# Opus / PCM Audio Pipeline
# ----------------------------------------------------------------------

class AudioPipeline:
    """Collects Opus packets, decodes them, and can write them to a WAV file."""

    def __init__(self):
        self.buffer: List[bytes] = []
        self.pcm_s16le: List[bytes] = []

    def add_opus_packet(self, packet: bytes):
        self.buffer.append(packet)
        self._decode_packet(packet)

    def _decode_packet(self, packet: bytes):
        try:
            import opuslib
            decoder = opuslib.Decoder(fs=16000, channels=1)
            pcm = decoder.decode(packet, frame_size=160)  # 20ms @16kHz
            self.pcm_s16le.append(pcm)
        except ImportError:
            # Fallback: just keep raw packet
            pass
        except Exception as e:
            print(f"Opus decode err: {e}")

    def save_wav(self, path: str = "test_audio.wav", sample_rate: int = 16000):
        if not self.pcm_s16le:
            print("No PCM data available")
            return
        import wave
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(b"".join(self.pcm_s16le))
        print(f"Saved WAV to {path}")

    def clear(self):
        self.buffer.clear()
        self.pcm_s16le.clear()


async def run_audio_capture(io: ABMateIO, delay: float = 10.0):
    """Start microphone and capture BLE notifications for `delay` seconds."""
    audio = AudioPipeline()
    io.audio_packets.clear()
    await io.request_mic()
    print(f"Listening for {delay} sec...")
    end = time.time() + delay
    while time.time() < end:
        await asyncio.sleep(0.1)
        # packets are collected in io.audio_packets by callback
        while io.audio_packets:
            p = io.audio_packets.pop(0)
            audio.add_opus_packet(p)
    audio.save_wav("test_audio.wav")
    return audio


# ----------------------------------------------------------------------
# OpenRouter Vision + Edge-TTS
# ----------------------------------------------------------------------

OPENROUTER_ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
MODEL_NAME = "z-ai/glm-5.3-flash"


def openrouter_vision_query(image_path: str, prompt: str, api_key: str) -> str:
    """Send image + prompt to OpenRouter and return text answer."""
    if not api_key:
        return "API key missing"
    import requests

    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()

    payload = {
        "model": MODEL_NAME,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/jpeg;base64,{b64}"}
                    },
                    {
                        "type": "text",
                        "text": "Sistem: Ești asistent în ochelari inteligenți. Răspunde concis, maxim 2-3 propoziții, în română.\n\n" + prompt
                    }
                ]
            }
        ],
        "max_tokens": 150,
        "temperature": 0.4,
    }

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

    resp = requests.post(OPENROUTER_ENDPOINT, json=payload, headers=headers, timeout=30)
    if resp.status_code != 200:
        return f"HTTP {resp.status_code}: {resp.text[:200]}"
    data = resp.json()
    try:
        return data["choices"][0]["message"]["content"].strip()
    except Exception:
        return "Unexpected response format"


async def speak_romanian(text: str, voice: str = "ro-RO-EmilNeural") -> None:
    """Generate Romanian TTS using edge-tts and play it."""
    try:
        import edge_tts
        import playsound  # you may need to install playsound
    except ImportError:
        print("edge-tts / playsound not installed; skipping TTS")
        return

    tmp_mp3 = os.path.join(tempfile.gettempdir(), "diag_response.mp3")
    communicate = edge_tts.Communicate(text, voice)
    await communicate.save(tmp_mp3)
    # Play using system default (works on Windows)
    playsound.playsound(tmp_mp3)


# ----------------------------------------------------------------------
# Interactive Menu
# ----------------------------------------------------------------------

async def menu():
    ble = BleScanner()
    io: Optional[ABMateIO] = None
    api_key = os.environ.get("OPENROUTER_API_KEY", "")

    while True:
        print("\n" + "="*60)
        print("   MT5 Ultra Diagnostic Rig")
        print("="*60)
        print("  1. BLE Scan & Dissect Advertisement (Show XOR MAC)")
        print("  2. Connect BLE & Subscribe to Notifications")
        print("  3. Trigger Hotspot AP Mode (cmdKey 0x10)")
        print("  4. Start RTSP Video & Capture Test Snapshot")
        print("  5. Start Audio Recording Test (10s capture to WAV)")
        print("  6. Full E2E Test (Snapshot -> OpenRouter GLM-5.3 -> Romanian TTS)")
        print("  7. Read Battery & Device Info (cmdKey 0x02)")
        print("  0. Exit")
        try:
            choice = input("\nSelect option: ").strip()
        except (KeyboardInterrupt, EOFError):
            break

        if choice == "0":
            if io:
                await io.disconnect()
            break
        elif choice == "1":
            await ble.interactive_scan()
        elif choice == "2":
            chosen = await ble.interactive_scan()
            if chosen:
                if io:
                    await io.disconnect()
                io = ABMateIO(chosen["address"])
                try:
                    await io.connect()
                except Exception as e:
                    print(f"Connection error: {e}")
                    io = None
        elif choice == "3":
            if io is None:
                print("Need to connect first (option 2)")
            else:
                print("\n[+] Sending Hotspot AP Activation Command (cmdKey 0x10)...")
                await io.request_hotspot_ap()
                print("[*] Waiting 5 seconds for device response & notifications...")
                for sec in range(5, 0, -1):
                    await asyncio.sleep(1.0)
                    while not io.notification_queue.empty():
                        print(f" -> {io.notification_queue.get()}")
                print(f"[*] Hotspot state: SSID='{io.hotspot_ssid or 'Not yet reported (check RAW RX logs above)'}'\n")
        elif choice == "4":
            result = capture_frame()
            if result["success"]:
                print(f"Snapshot saved: {result['path']} ({result['width']}x{result['height']}, {result['size_bytes']} bytes)")
            else:
                print(f"Snapshot error: {result['error']}")
        elif choice == "5":
            if io is None:
                print("Need to connect first (option 2)")
            else:
                await run_audio_capture(io, delay=10.0)
        elif choice == "6":
            if io is None:
                print("Need to connect first (option 2)")
                continue
            # capture snapshot
            snap = capture_frame(output_path="e2e_snapshot.jpg")
            if not snap["success"]:
                print("Failed to capture image")
                continue
            # if OpenRouter API key not set, ask
            if not api_key:
                api_key = input("Enter OpenRouter API key: ").strip()
            prompt = "Descrie ce vezi în imagine și explică ce este important."
            answer = openrouter_vision_query(snap["path"], prompt, api_key)
            print(f"AI: {answer}")
            await speak_romanian(answer)
        elif choice == "7":
            if io is None:
                print("Need to connect first (option 2)")
            else:
                print("\n[+] Requesting Battery Status (cmdKey 0x02)...")
                await io.request_battery()
                print("[*] Waiting 3 seconds for response...")
                for _ in range(6):
                    await asyncio.sleep(0.5)
                    while not io.notification_queue.empty():
                        print(f" -> {io.notification_queue.get()}")
                print(f"[+] Current Battery Level: {io.battery_level}%\n")
        else:
            print("Invalid option")


if __name__ == "__main__":
    try:
        asyncio.run(menu())
    except KeyboardInterrupt:
        print("\nExiting.")
