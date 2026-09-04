\# MASTER ARCHITECTURE: AI SMART GLASSES (MT5 ULTRA / OPENROUTER)



\## 1. HARDWARE \& PROTOCOLS (Topstep / ABMate Protocol)

\- Device: MT5 Ultra Smart Glasses (SoC RTOS Bluetrum/Allwinner).

\- BLE Service UUID: B6632277-0642-458B-A7A0-23FB1DC92C93

\- BLE Manufacturer Data MAC extraction: MAC\[i] = ManufacturerData\[5+i] XOR 0xAD (i = 0..5)

\- ABMate BLE Packet Header (5 bytes):

&#x20; \[cmdKey (1B) | cmdType (1B) | seqNum (1B) | frameSeqNum (1B) | totalFrames (1B) | payload]

&#x20; - cmdType: 0x01 = Request, 0x02 = Response, 0x03 = Notification/Event

\- Key Commands:

&#x20; - Hotspot AP config: cmdKey=0x10, cmdType=0x01, payload=0x00 (AP Mode)

&#x20; - RTSP Live Stream Start: cmdKey=0x12, cmdType=0x01, payload=0x01

&#x20; - AI Audio Recording Start (Mic): cmdKey=0x14, cmdType=0x01, payload=0x00

\- Audio Specs:

&#x20; - BLE notifications deliver Opus packets @ 16kHz Mono -> decoded with opuslib to Linear PCM S16LE.

\- Video Stream:

&#x20; - Endpoint: rtsp://192.168.43.1:554/live

&#x20; - Strategy: Capture on-demand JPEG snapshots (or 1 FPS) to protect the 300mAh battery.



\## 2. BACKEND \& AI STACK

\- LLM / Vision Provider: OpenRouter API (https://openrouter.ai/api/v1)

\- Model: z-ai/glm-5.3-flash (or qwen/qwen-2.5-vl-72b-instruct / google/gemini-2.0-flash-001)

\- Speech-to-Text: faster-whisper (local CPU/GPU, language='ro')

\- Text-to-Speech: edge-tts (voice: ro-RO-EmilNeural)

\- Output Language: Fluent, natural, concise Romanian (< 2-3 sentences).

