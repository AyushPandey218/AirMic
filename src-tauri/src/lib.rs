use std::net::{TcpListener, TcpStream, UdpSocket};
use std::thread;
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, Ordering, AtomicU64};
use std::collections::HashSet;
use std::time::{Instant, Duration};
use tauri::{AppHandle, Emitter, Manager};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rand::Rng;
use ringbuf::{HeapRb, HeapProd, HeapCons};
use ringbuf::traits::*;

const MIC_OUTPUT_FRAMES: u32 = 480;      // 10 ms at 48 kHz

// Audio routing configuration state
struct AudioRoutingConfig {
    enable_speakers: AtomicBool,
    enable_virtual_mic: AtomicBool,
}

struct TransferStats {
    total_mic_bytes: AtomicU64,
    total_speaker_bytes: AtomicU64,
}

struct TrayConfig {
    minimize_to_tray: AtomicBool,
}

enum PlayoutTarget {
    Speakers,
    VirtualMic,
}

// Windows WASAPI streams are actually Send; cpal conservatively marks !Send for portability.
#[allow(dead_code)]
struct SendStream(Option<cpal::Stream>);
unsafe impl Send for SendStream {}

// Speaker stream (PC audio → phone) control
struct SpeakerStreamState {
    is_streaming: AtomicBool,
    handle: Mutex<Option<SendStream>>,
}

// Store the connected phone's IP for speaker stream targeting
struct ConnectedPhoneIp {
    ip: Mutex<String>,
}

// OTP Pairing and discovery state structure
struct PairingState {
    active_otp: String,
    otp_expiry: Instant,
    paired_identifiers: HashSet<String>,
}

fn load_paired_devices() -> HashSet<String> {
    let path = std::env::current_dir().unwrap_or_default().join("paired_devices.json");
    if path.exists() {
        if let Ok(content) = std::fs::read_to_string(path) {
            if let Ok(list) = serde_json::from_str::<HashSet<String>>(&content) {
                return list;
            }
        }
    }
    HashSet::new()
}

fn save_paired_devices(devices: &HashSet<String>) {
    let path = std::env::current_dir().unwrap_or_default().join("paired_devices.json");
    if let Ok(content) = serde_json::to_string(devices) {
        let _ = std::fs::write(path, content);
    }
}

fn generate_6_digit_otp() -> String {
    let mut rng = rand::thread_rng();
    let code: u32 = rng.gen_range(100000..1000000);
    code.to_string()
}

fn get_local_ip_udp() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    socket.local_addr().ok().map(|addr| addr.ip().to_string())
}

fn is_private_ip(ip: std::net::IpAddr) -> bool {
    match ip {
        std::net::IpAddr::V4(ipv4) => {
            let octets = ipv4.octets();
            octets[0] == 10
                || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168)
        }
        _ => false,
    }
}

fn get_local_ip_fallback() -> Option<String> {
    if let Ok(interfaces) = get_if_addrs::get_if_addrs() {
        for interface in interfaces {
            if !interface.is_loopback() {
                let ip = interface.ip();
                if is_private_ip(ip) {
                    return Some(ip.to_string());
                }
            }
        }
    }
    None
}

#[tauri::command]
fn get_local_ip() -> String {
    get_local_ip_udp()
        .or_else(get_local_ip_fallback)
        .unwrap_or_else(|| "127.0.0.1".to_string())
}

#[tauri::command]
fn get_driver_status() -> bool {
    let host = cpal::default_host();
    let mut has_speaker = false;
    let mut has_mic = false;

    if let Ok(devices) = host.output_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                let name_lower = name.to_lowercase();
                if name_lower.contains("cable-a") || name_lower.contains("cable a") || name_lower.contains("cable input") || name_lower.contains("cable in") || name_lower.contains("airmic speaker") {
                    has_speaker = true;
                    break;
                }
            }
        }
    }

    if let Ok(devices) = host.input_devices() {
        for d in devices {
            if let Ok(name) = d.name() {
                let name_lower = name.to_lowercase();
                if name_lower.contains("cable-b") || name_lower.contains("cable b") || name_lower.contains("cable output") || name_lower.contains("cable out") || name_lower.contains("airmic virtual microphone") {
                    has_mic = true;
                    break;
                }
            }
        }
    }

    let ok = has_speaker && has_mic;
    if !ok {
        eprintln!("Driver status: speaker_found={}, mic_found={}", has_speaker, has_mic);
    }
    ok
}

#[tauri::command]
fn update_audio_routing(
    enable_speakers: bool,
    enable_virtual_mic: bool,
    state: tauri::State<Arc<AudioRoutingConfig>>,
) {
    state.enable_speakers.store(enable_speakers, Ordering::SeqCst);
    state.enable_virtual_mic.store(enable_virtual_mic, Ordering::SeqCst);
    println!("Updated routing config: speakers={}, virtual_mic={}", enable_speakers, enable_virtual_mic);
}

#[tauri::command]
fn update_tray_config(
    minimize_to_tray: bool,
    state: tauri::State<Arc<TrayConfig>>,
) {
    state.minimize_to_tray.store(minimize_to_tray, Ordering::SeqCst);
    println!("Updated tray config: minimize_to_tray={}", minimize_to_tray);
}

#[tauri::command]
fn get_pairing_code(state: tauri::State<Arc<Mutex<PairingState>>>) -> String {
    let mut s = state.lock().unwrap();
    if s.otp_expiry.elapsed() >= Duration::from_secs(300) {
        s.active_otp = generate_6_digit_otp();
        s.otp_expiry = Instant::now();
    }
    s.active_otp.clone()
}

#[tauri::command]
fn regenerate_pairing_code(
    app_handle: AppHandle,
    state: tauri::State<Arc<Mutex<PairingState>>>,
) -> String {
    let mut s = state.lock().unwrap();
    let new_otp = generate_6_digit_otp();
    s.active_otp = new_otp.clone();
    s.otp_expiry = Instant::now();
    println!("Manually regenerated pairing code: {}", new_otp);
    let _ = app_handle.emit("pairing-code-changed", &s.active_otp);
    s.active_otp.clone()
}

// WASAPI Loopback Capture Helpers using winapi
use winapi::shared::wtypes::PROPERTYKEY;
use winapi::shared::guiddef::GUID;
use winapi::shared::minwindef::DWORD;
use winapi::um::mmdeviceapi::{IMMDevice, IMMDeviceEnumerator, IMMDeviceCollection, CLSID_MMDeviceEnumerator, eRender, eConsole, DEVICE_STATE_ACTIVE};
use winapi::um::propsys::IPropertyStore;
use winapi::um::combaseapi::{CoCreateInstance, CoInitializeEx, CoUninitialize, COINITBASE_MULTITHREADED, PropVariantClear, CLSCTX_ALL};
use winapi::um::audioclient::{IAudioClient, IAudioCaptureClient};
use winapi::um::audiosessiontypes::AUDCLNT_SHAREMODE_SHARED;
use winapi::shared::winerror::S_OK;
use winapi::shared::mmreg::{WAVEFORMATEX, WAVEFORMATEXTENSIBLE};
use winapi::shared::ksmedia::KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
use winapi::Interface;
use std::slice;
use std::ptr;

// PROPERTYKEY for FriendlyName: {a45c254e-df1c-4efd-8020-67d146a850e0}, 2
const PKEY_DEVICE_FRIENDLY_NAME: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID {
        Data1: 0xa45c254e,
        Data2: 0xdf1c,
        Data3: 0x4efd,
        Data4: [0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0],
    },
    pid: 2,
};

const STGM_READ: DWORD = 0x00000000;
const AUDCLNT_STREAMFLAGS_LOOPBACK: u32 = 0x00020000;

fn is_guid_equal(a: &GUID, b: &GUID) -> bool {
    a.Data1 == b.Data1 && a.Data2 == b.Data2 && a.Data3 == b.Data3 && a.Data4 == b.Data4
}

fn resample(input: &[f32], channels: usize, source_rate: u32, target_rate: u32, fraction: &mut f64) -> Vec<f32> {
    if source_rate == target_rate {
        return input.to_vec();
    }
    let ratio = source_rate as f64 / target_rate as f64;
    let num_input_frames = input.len() / channels;
    if num_input_frames == 0 {
        return Vec::new();
    }
    let num_output_frames = (num_input_frames as f64 / ratio).round() as usize;
    let mut output = Vec::with_capacity(num_output_frames * channels);
    
    for i in 0..num_output_frames {
        let pos = i as f64 * ratio + *fraction;
        let idx = pos.floor() as usize;
        let next_idx = idx + 1;
        let t = pos - pos.floor();
        
        if next_idx < num_input_frames {
            for c in 0..channels {
                let s1 = input[idx * channels + c];
                let s2 = input[next_idx * channels + c];
                let s = s1 * (1.0 - t as f32) + s2 * (t as f32);
                output.push(s);
            }
        } else {
            for c in 0..channels {
                output.push(input[(num_input_frames - 1) * channels + c]);
            }
        }
    }
    
    let consumed = num_output_frames as f64 * ratio;
    *fraction = *fraction + consumed - num_input_frames as f64;
    output
}

#[tauri::command]
fn start_speaker_stream(
    app_handle: AppHandle,
    phone_ip_state: tauri::State<Arc<ConnectedPhoneIp>>,
    speaker_state: tauri::State<Arc<SpeakerStreamState>>,
    transfer_stats: tauri::State<Arc<TransferStats>>,
) -> Result<String, String> {
    if speaker_state.is_streaming.load(Ordering::SeqCst) {
        return Err("Speaker stream is already running.".to_string());
    }

    let phone_ip = phone_ip_state.ip.lock().unwrap().clone();
    if phone_ip.is_empty() {
        return Err("No phone connected.".to_string());
    }

    println!("Starting speaker stream to phone at {}:9093 using WASAPI Loopback Capture", phone_ip);

    speaker_state.is_streaming.store(true, Ordering::SeqCst);
    let _ = app_handle.emit("speaker-stream-status", "Streaming");

    let is_streaming = speaker_state.inner().clone();
    let stats = transfer_stats.inner().clone();
    let target = format!("{}:9093", phone_ip);

    thread::spawn(move || {
        unsafe {
            let hr = CoInitializeEx(ptr::null_mut(), COINITBASE_MULTITHREADED);
            if hr != S_OK && hr != 0x00040010 { // RPC_E_CHANGED_MODE is fine
                eprintln!("CoInitializeEx failed: hr=0x{:X}", hr);
            }

            let run_capture = || -> Result<(), String> {
                let mut enumerator: *mut IMMDeviceEnumerator = ptr::null_mut();
                let hr = CoCreateInstance(
                    &CLSID_MMDeviceEnumerator,
                    ptr::null_mut(),
                    CLSCTX_ALL,
                    &IMMDeviceEnumerator::uuidof(),
                    &mut enumerator as *mut *mut IMMDeviceEnumerator as *mut *mut _,
                );
                if hr != S_OK {
                    return Err(format!("Failed to create MMDeviceEnumerator: 0x{:X}", hr));
                }
                let enumerator = &*enumerator;

                let mut collection: *mut IMMDeviceCollection = ptr::null_mut();
                let hr = enumerator.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &mut collection);
                if hr != S_OK {
                    enumerator.Release();
                    return Err(format!("Failed to enumerate audio endpoints: 0x{:X}", hr));
                }
                let collection = &*collection;

                let mut count: u32 = 0;
                collection.GetCount(&mut count);

                let mut target_device: *mut IMMDevice = ptr::null_mut();
                // Match both pre-rename (CABLE-A) and post-rename (AirMic Speaker) names
                let keywords = ["airmic speaker", "cable-a", "cable a", "cable input", "cable in"];

                for i in 0..count {
                    let mut device: *mut IMMDevice = ptr::null_mut();
                    if collection.Item(i, &mut device) == S_OK {
                        let dev = &*device;
                        let mut store: *mut IPropertyStore = ptr::null_mut();
                        if dev.OpenPropertyStore(STGM_READ, &mut store) == S_OK {
                            let store = &*store;
                            let mut prop = std::mem::zeroed();
                            if store.GetValue(&PKEY_DEVICE_FRIENDLY_NAME, &mut prop) == S_OK {
                                let vt = prop.vt;
                                if vt == 31 { // VT_LPWSTR
                                    let pwsz = *(&prop.data as *const _ as *const *mut u16);
                                    if !pwsz.is_null() {
                                        let mut len = 0;
                                        while *pwsz.offset(len) != 0 {
                                            len += 1;
                                        }
                                        let name_slice = slice::from_raw_parts(pwsz, len as usize);
                                        let name = String::from_utf16_lossy(name_slice);
                                        let name_lower = name.to_lowercase();
                                        
                                        let mut matched = false;
                                        for &kw in &keywords {
                                            if name_lower.contains(kw) {
                                                matched = true;
                                                break;
                                            }
                                        }
                                        
                                        if matched {
                                            println!("Selected loopback device: {}", name);
                                            target_device = device;
                                            PropVariantClear(&mut prop);
                                            store.Release();
                                            break;
                                        }
                                    }
                                }
                            }
                            PropVariantClear(&mut prop);
                            store.Release();
                        }
                        if !target_device.is_null() {
                            break;
                        }
                        dev.Release();
                    }
                }

                collection.Release();

                if target_device.is_null() {
                    println!("No matching loopback device found. Using default render device.");
                    let mut device: *mut IMMDevice = ptr::null_mut();
                    let hr = enumerator.GetDefaultAudioEndpoint(eRender, eConsole, &mut device);
                    if hr != S_OK {
                        enumerator.Release();
                        return Err(format!("Failed to get default audio endpoint: 0x{:X}", hr));
                    }
                    target_device = device;
                }

                enumerator.Release();
                let device = &*target_device;

                let mut audio_client: *mut IAudioClient = ptr::null_mut();
                let hr = device.Activate(
                    &IAudioClient::uuidof(),
                    CLSCTX_ALL,
                    ptr::null_mut(),
                    &mut audio_client as *mut *mut IAudioClient as *mut *mut _,
                );
                if hr != S_OK {
                    device.Release();
                    return Err(format!("Failed to activate IAudioClient: 0x{:X}", hr));
                }
                let audio_client = &*audio_client;

                let mut mix_format: *mut WAVEFORMATEX = ptr::null_mut();
                let hr = audio_client.GetMixFormat(&mut mix_format);
                if hr != S_OK {
                    audio_client.Release();
                    device.Release();
                    return Err(format!("Failed to get mix format: 0x{:X}", hr));
                }
                let format = &*mix_format;
                
                let source_rate = format.nSamplesPerSec;
                let device_channels = format.nChannels as usize;
                let is_float = if format.wFormatTag == winapi::shared::mmreg::WAVE_FORMAT_EXTENSIBLE {
                    let ext = &*(mix_format as *const WAVEFORMATEXTENSIBLE);
                    let sub_format = ext.SubFormat;
                    is_guid_equal(&sub_format, &KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)
                } else {
                    format.wFormatTag == winapi::shared::mmreg::WAVE_FORMAT_IEEE_FLOAT
                };
                
                println!("Mix format: rate={}, channels={}, float={}", source_rate, device_channels, is_float);

                let hr = audio_client.Initialize(
                    AUDCLNT_SHAREMODE_SHARED,
                    AUDCLNT_STREAMFLAGS_LOOPBACK,
                    1000000,
                    0,
                    mix_format,
                    ptr::null(),
                );
                
                winapi::um::combaseapi::CoTaskMemFree(mix_format as *mut _);

                if hr != S_OK {
                    audio_client.Release();
                    device.Release();
                    return Err(format!("Failed to initialize IAudioClient in loopback: 0x{:X}", hr));
                }

                let mut capture_client: *mut IAudioCaptureClient = ptr::null_mut();
                let hr = audio_client.GetService(
                    &IAudioCaptureClient::uuidof(),
                    &mut capture_client as *mut *mut IAudioCaptureClient as *mut *mut _,
                );
                if hr != S_OK {
                    audio_client.Release();
                    device.Release();
                    return Err(format!("Failed to get IAudioCaptureClient: 0x{:X}", hr));
                }
                let capture_client = &*capture_client;

                let hr = audio_client.Start();
                if hr != S_OK {
                    capture_client.Release();
                    audio_client.Release();
                    device.Release();
                    return Err(format!("Failed to start IAudioClient: 0x{:X}", hr));
                }

                let socket = UdpSocket::bind("0.0.0.0:0").map_err(|e| format!("Failed to bind UDP socket: {}", e))?;
                // 800ms ring buffer — absorbs WASAPI burst delivery without overflow
                let (mut prod, mut cons) = HeapRb::<i16>::new(76800).split();
                
                let is_streaming_sender = is_streaming.clone();
                let stats_sender = stats.clone();
                let target_sender = target.clone();
                
                thread::spawn(move || {
                    use std::time::Instant;
                    let send_interval = Duration::from_millis(10); // one 960-sample packet = 10ms at 48kHz stereo
                    let mut next_send = Instant::now() + send_interval;
                    let mut byte_buf = vec![0u8; 1920];
                    let mut samples = vec![0i16; 960];

                    while is_streaming_sender.is_streaming.load(Ordering::SeqCst) {
                        // Pop real audio, or fill with silence to keep phone AudioTrack alive
                        if cons.occupied_len() >= 960 {
                            let _ = cons.pop_slice(&mut samples);
                        } else {
                            // Buffer underrun — send silence to prevent phone dropout
                            samples.fill(0);
                        }

                        // Serialise i16 → bytes
                        for (idx, &s) in samples.iter().enumerate() {
                            let bytes = s.to_le_bytes();
                            byte_buf[idx * 2]     = bytes[0];
                            byte_buf[idx * 2 + 1] = bytes[1];
                        }

                        if socket.send_to(&byte_buf, &target_sender).is_ok() {
                            stats_sender.total_speaker_bytes.fetch_add(1920, Ordering::Relaxed);
                        }

                        // Pace: sleep until exactly 10ms after last send
                        let now = Instant::now();
                        if next_send > now {
                            thread::sleep(next_send - now);
                        }
                        next_send += send_interval;

                        // If we fell behind by more than 30ms, reset the clock
                        // (prevents a burst of catch-up sends after a stall)
                        if Instant::now() > next_send + Duration::from_millis(30) {
                            next_send = Instant::now() + send_interval;
                        }
                    }
                    println!("Speaker UDP sender loop stopped.");
                });

                let mut resample_fraction = 0.0;
                
                while is_streaming.is_streaming.load(Ordering::SeqCst) {
                    let mut packet_size: u32 = 0;
                    let hr = capture_client.GetNextPacketSize(&mut packet_size);
                    if hr != S_OK {
                        thread::sleep(Duration::from_millis(3));
                        continue;
                    }
                    
                    if packet_size > 0 {
                        let mut p_data: *mut u8 = ptr::null_mut();
                        let mut num_frames: u32 = 0;
                        let mut flags: u32 = 0;
                        let mut dev_pos: u64 = 0;
                        let mut qpc_pos: u64 = 0;
                        
                        let hr = capture_client.GetBuffer(
                            &mut p_data,
                            &mut num_frames,
                            &mut flags,
                            &mut dev_pos,
                            &mut qpc_pos,
                        );
                        
                        if hr == S_OK && num_frames > 0 {
                            let is_silent = (flags & winapi::um::audioclient::AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                            let total_samples = num_frames as usize * device_channels;
                            
                            let mut f32_samples = vec![0.0f32; total_samples];
                            if !is_silent && !p_data.is_null() {
                                if is_float {
                                    let raw_slice = slice::from_raw_parts(p_data as *const f32, total_samples);
                                    f32_samples.copy_from_slice(raw_slice);
                                } else {
                                    let raw_slice = slice::from_raw_parts(p_data as *const i16, total_samples);
                                    for (i, &s) in raw_slice.iter().enumerate() {
                                        f32_samples[i] = s as f32 / 32768.0;
                                    }
                                }
                            }
                            
                            let resampled_f32 = resample(
                                &f32_samples,
                                device_channels,
                                source_rate,
                                48000,
                                &mut resample_fraction,
                            );
                            
                            let mut i16_stereo = Vec::with_capacity((resampled_f32.len() / device_channels) * 2);
                            if device_channels == 2 {
                                for &s in &resampled_f32 {
                                    let sample_i16 = (s * 32768.0).clamp(-32768.0, 32767.0) as i16;
                                    i16_stereo.push(sample_i16);
                                }
                            } else if device_channels == 1 {
                                for &s in &resampled_f32 {
                                    let sample_i16 = (s * 32768.0).clamp(-32768.0, 32767.0) as i16;
                                    i16_stereo.push(sample_i16);
                                    i16_stereo.push(sample_i16);
                                }
                            } else {
                                for chunk in resampled_f32.chunks_exact(device_channels) {
                                    let l = (chunk[0] * 32768.0).clamp(-32768.0, 32767.0) as i16;
                                    let r = (chunk[1] * 32768.0).clamp(-32768.0, 32767.0) as i16;
                                    i16_stereo.push(l);
                                    i16_stereo.push(r);
                                }
                            }
                            
                            let _ = prod.push_slice(&i16_stereo);
                            
                            capture_client.ReleaseBuffer(num_frames);
                        }
                    } else {
                        thread::sleep(Duration::from_millis(3));
                    }
                }

                let _ = audio_client.Stop();
                capture_client.Release();
                audio_client.Release();
                device.Release();
                println!("WASAPI loopback capture stopped cleanly.");
                Ok(())
            };

            if let Err(e) = run_capture() {
                eprintln!("Error in WASAPI loopback capture thread: {}", e);
                is_streaming.is_streaming.store(false, Ordering::SeqCst);
            }

            CoUninitialize();
        }
    });

    println!("Speaker loopback capture stream started successfully.");
    Ok("Speaker stream started.".to_string())
}

#[tauri::command]
fn stop_speaker_stream(
    app_handle: AppHandle,
    speaker_state: tauri::State<Arc<SpeakerStreamState>>,
) -> Result<String, String> {
    if !speaker_state.is_streaming.load(Ordering::SeqCst) {
        return Err("Speaker stream is not running.".to_string());
    }

    println!("Stopping speaker stream...");
    speaker_state.is_streaming.store(false, Ordering::SeqCst);
    let _ = app_handle.emit("speaker-stream-status", "Idle");

    println!("Speaker stream stopped successfully.");
    Ok("Speaker stream stopped.".to_string())
}

fn start_audio_playback(
    mut cons: HeapCons<i16>,
    target: PlayoutTarget,
) -> Option<cpal::Stream> {
    let host = cpal::default_host();
    let device = match target {
        PlayoutTarget::Speakers => match host.default_output_device() {
            Some(d) => d,
            None => {
                eprintln!("No default audio output device found.");
                return None;
            }
        },
        PlayoutTarget::VirtualMic => {
            let mut target_device = None;
            if let Ok(devices) = host.output_devices() {
                let devices_vec: Vec<_> = devices.collect();
                // Priority 1: Post-install AirMic branded names
                for d in &devices_vec {
                    if let Ok(name) = d.name() {
                        let name_lower = name.to_lowercase();
                        if name_lower.contains("airmic mic in") || name_lower.contains("airmic mic") {
                            target_device = Some(d.clone());
                            break;
                        }
                    }
                }
                // Priority 2: Pre-install VB-Cable B raw names
                if target_device.is_none() {
                    for d in &devices_vec {
                        if let Ok(name) = d.name() {
                            let name_lower = name.to_lowercase();
                            if name_lower.contains("cable-b") || name_lower.contains("cable b") {
                                target_device = Some(d.clone());
                                break;
                            }
                        }
                    }
                }
                // Priority 3: Standard single VB-Cable Input fallback
                if target_device.is_none() {
                    for d in &devices_vec {
                        if let Ok(name) = d.name() {
                            let name_lower = name.to_lowercase();
                            if name_lower.contains("cable input") || name_lower.contains("cable in") {
                                target_device = Some(d.clone());
                                break;
                            }
                        }
                    }
                }
            }
            match target_device {
                Some(d) => d,
                None => {
                    eprintln!("Virtual Mic device (AirMic Mic / CABLE-B) not found.");
                    return None;
                }
            }
        }
    };

    let supported_config = match device.default_output_config() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to get default output config: {}", e);
            return None;
        }
    };

    let sample_format = supported_config.sample_format();
    let mut config: cpal::StreamConfig = supported_config.into();
    // Set 10ms frame size for low latency playback buffer (480 frames at 48kHz)
    config.buffer_size = cpal::BufferSize::Fixed(MIC_OUTPUT_FRAMES);
    let channels = config.channels;

    println!("Targeting audio output device: {:?}", device.name().unwrap_or_else(|_| "Unknown Device".to_string()));
    println!("Audio config: channels={}, sample_rate={:?}, format={:?}", channels, config.sample_rate, sample_format);

    // Initial buffering settings
    let mut target_delay = 480; // 10ms initial target delay (mono samples)
    let mut is_buffering = true;
    let mut consecutive_success = 0;

    let stream = match sample_format {
        cpal::SampleFormat::F32 => {
            device.build_output_stream(
                &config,
                move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                    let frames = data.len() / channels as usize;
                    let available = cons.occupied_len();
                    
                    // Check if we need to catch up (excess latency)
                    let max_delay = target_delay + 480 * 2; // 20ms safety margin
                    if available > max_delay {
                        let excess = available - target_delay;
                        let _ = cons.skip(excess);
                    }
                    
                    if is_buffering {
                        if cons.occupied_len() >= target_delay {
                            is_buffering = false;
                        } else {
                            // Silence
                            for out in data.iter_mut() {
                                *out = 0.0;
                            }
                            return;
                        }
                    }
                    
                    let to_read = frames.min(cons.occupied_len());
                    let mut read_samples = vec![0i16; to_read];
                    let _ = cons.pop_slice(&mut read_samples);
                    
                    let mut iter = read_samples.iter();
                    for frame in data.chunks_mut(channels as usize) {
                        let sample = iter.next().copied().unwrap_or(0i16) as f32 / 32768.0;
                        for out in frame.iter_mut() {
                            *out = sample;
                        }
                    }
                    
                    if to_read < frames {
                        is_buffering = true;
                        if target_delay < 480 * 6 { // Max 60ms delay
                            target_delay += 480;
                        }
                        consecutive_success = 0;
                    } else {
                        consecutive_success += frames;
                        if consecutive_success >= 48000 * 3 { // 3 seconds of stable playout
                            if target_delay > 480 { // Min 10ms delay
                                target_delay -= 480;
                            }
                            consecutive_success = 0;
                        }
                    }
                },
                |err| eprintln!("Audio output stream error: {}", err),
                None
            ).ok()
        }
        cpal::SampleFormat::I16 => {
            device.build_output_stream(
                &config,
                move |data: &mut [i16], _: &cpal::OutputCallbackInfo| {
                    let frames = data.len() / channels as usize;
                    let available = cons.occupied_len();
                    
                    // Check if we need to catch up (excess latency)
                    let max_delay = target_delay + 480 * 2;
                    if available > max_delay {
                        let excess = available - target_delay;
                        let _ = cons.skip(excess);
                    }
                    
                    if is_buffering {
                        if cons.occupied_len() >= target_delay {
                            is_buffering = false;
                        } else {
                            // Silence
                            for out in data.iter_mut() {
                                *out = 0;
                            }
                            return;
                        }
                    }
                    
                    let to_read = frames.min(cons.occupied_len());
                    let mut read_samples = vec![0i16; to_read];
                    let _ = cons.pop_slice(&mut read_samples);
                    
                    let mut iter = read_samples.iter();
                    for frame in data.chunks_mut(channels as usize) {
                        let sample = iter.next().copied().unwrap_or(0i16);
                        for out in frame.iter_mut() {
                            *out = sample;
                        }
                    }
                    
                    if to_read < frames {
                        is_buffering = true;
                        if target_delay < 480 * 6 {
                            target_delay += 480;
                        }
                        consecutive_success = 0;
                    } else {
                        consecutive_success += frames;
                        if consecutive_success >= 48000 * 3 {
                            if target_delay > 480 {
                                target_delay -= 480;
                            }
                            consecutive_success = 0;
                        }
                    }
                },
                |err| eprintln!("Audio output stream error: {}", err),
                None
            ).ok()
        }
        _ => {
            eprintln!("Unsupported default sample format: {:?}", sample_format);
            None
        }
    };

    let stream = stream?;
    if let Err(e) = stream.play() {
        eprintln!("Failed to play output stream: {}", e);
        return None;
    }

    Some(stream)
}

fn handle_connection(
    stream: &mut TcpStream,
    app_handle: AppHandle,
    is_client_connected: Arc<AtomicBool>,
    pairing_state: Arc<Mutex<PairingState>>,
    phone_ip_state: Arc<ConnectedPhoneIp>,
    speaker_state: Arc<SpeakerStreamState>,
    transfer_stats: Arc<TransferStats>,
) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();

    // 1. Read handshake message: HELLO_AIRMIC <otp_or_identifier>
    reader.read_line(&mut line)?;
    let parts: Vec<&str> = line.trim().split_whitespace().collect();
    if parts.is_empty() || parts[0] != "HELLO_AIRMIC" {
        println!("Invalid handshake format: {}", line);
        let _ = stream.write_all(b"REJECTED\n");
        let _ = stream.flush();
        return Ok(());
    }

    let credential = if parts.len() >= 2 { parts[1] } else { "" };
    let mut is_authenticated = false;
    let mut is_new_pairing = false;
    let mut generated_id = String::new();

    {
        let mut state = pairing_state.lock().unwrap();
        let is_otp_valid = state.otp_expiry.elapsed() < Duration::from_secs(300);
        if is_otp_valid && credential == state.active_otp {
            is_authenticated = true;
            is_new_pairing = true;
            generated_id = format!("{:08x}", rand::random::<u64>());
            state.paired_identifiers.insert(generated_id.clone());
            save_paired_devices(&state.paired_identifiers);
            println!("New device paired successfully. Identifier generated: {}", generated_id);
            
            // Force code regeneration on successful pairing to prevent code reuse
            state.active_otp = generate_6_digit_otp();
            state.otp_expiry = Instant::now();
            let _ = app_handle.emit("pairing-code-changed", &state.active_otp);
        } else if state.paired_identifiers.contains(credential) {
            is_authenticated = true;
            println!("Known device reconnected using identifier: {}", credential);
        }
    }

    if !is_authenticated {
        println!("Authentication failed for credential: {}", credential);
        let _ = stream.write_all(b"REJECTED\n");
        let _ = stream.flush();
        return Ok(());
    }

    // 2. Respond with WELCOME_AIRMIC
    if is_new_pairing {
        let welcome_msg = format!("WELCOME_AIRMIC {}\n", generated_id);
        stream.write_all(welcome_msg.as_bytes())?;
    } else {
        stream.write_all(b"WELCOME_AIRMIC\n")?;
    }
    stream.flush()?;

    // 3. Store the phone's IP for speaker stream targeting
    if let Ok(peer_addr) = stream.peer_addr() {
        let ip_str = peer_addr.ip().to_string();
        *phone_ip_state.ip.lock().unwrap() = ip_str;
        println!("Phone IP stored for speaker stream: {}", peer_addr.ip());
    }

    // 4. Mark client as connected and update UI status
    is_client_connected.store(true, Ordering::SeqCst);
    let _ = app_handle.emit("connection-status", "Connected");
    transfer_stats.total_mic_bytes.store(0, Ordering::Relaxed);
    transfer_stats.total_speaker_bytes.store(0, Ordering::Relaxed);

    // 4. Read client metadata JSON (next line)
    line.clear();
    reader.read_line(&mut line)?;
    let metadata_str = line.trim().to_string();
    println!("Received client metadata: {}", metadata_str);

    // Emit the metadata string directly to the frontend
    let _ = app_handle.emit("client-metadata", metadata_str);

    // 5. Keep connection open / wait until client disconnects (EOF)
    let mut buffer = [0; 1024];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => {
                println!("Client disconnected cleanly.");
                break;
            }
            Ok(_) => {
                // Heartbeat / heartbeats
            }
            Err(e) => {
                println!("Connection error: {}", e);
                break;
            }
        }
    }

    // 6. Clear phone IP on disconnect
    phone_ip_state.ip.lock().unwrap().clear();

    // 7. Stop speaker stream if running
    if speaker_state.is_streaming.load(Ordering::SeqCst) {
        *speaker_state.handle.lock().unwrap() = None;
        speaker_state.is_streaming.store(false, Ordering::SeqCst);
        println!("Speaker stream stopped due to client disconnect.");
    }

    // 8. Reset UI status and clear metadata on disconnect
    is_client_connected.store(false, Ordering::SeqCst);
    let _ = app_handle.emit("connection-status", "Listening");
    let _ = app_handle.emit("client-metadata", "");

    Ok(())

}

fn start_tcp_listener(
    app_handle: AppHandle,
    is_client_connected: Arc<AtomicBool>,
    pairing_state: Arc<Mutex<PairingState>>,
    phone_ip_state: Arc<ConnectedPhoneIp>,
    speaker_state: Arc<SpeakerStreamState>,
    transfer_stats: Arc<TransferStats>,
) {
    thread::spawn(move || {
        let listener = match TcpListener::bind("0.0.0.0:9090") {
            Ok(l) => l,
            Err(e) => {
                eprintln!("Failed to bind TCP listener to port 9090: {}", e);
                return;
            }
        };

        for stream in listener.incoming() {
            match stream {
                Ok(mut stream) => {
                    let handle_clone = app_handle.clone();
                    let connected_clone = is_client_connected.clone();
                    let pairing_clone = pairing_state.clone();
                    let ip_clone = phone_ip_state.clone();
                    let speaker_clone = speaker_state.clone();
                    let stats_clone = transfer_stats.clone();
                    let _ = handle_connection(&mut stream, handle_clone, connected_clone, pairing_clone, ip_clone, speaker_clone, stats_clone);
                }
                Err(e) => {
                    eprintln!("Failed to accept incoming stream: {}", e);
                }
            }
        }
    });
}

struct StreamStats {
    packets: u64,
    bytes_received: u64,
    last_packet_time: Option<Instant>,
    status: &'static str,
}

fn start_udp_listener(
    app_handle: AppHandle,
    is_client_connected: Arc<AtomicBool>,
    routing_config: Arc<AudioRoutingConfig>,
    transfer_stats: Arc<TransferStats>,
    speaker_state: Arc<SpeakerStreamState>,
) {
    thread::spawn(move || {
        let socket = match UdpSocket::bind("0.0.0.0:9091") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to bind UDP socket to port 9091: {}", e);
                return;
            }
        };

        socket.set_read_timeout(Some(Duration::from_millis(500))).ok();

        let mut buf = [0u8; 65536];
        let mut stats = StreamStats {
            packets: 0,
            bytes_received: 0,
            last_packet_time: None,
            status: "Stopped",
        };

        let mut speaker_stream: Option<cpal::Stream> = None;
        let mut virtual_mic_stream: Option<cpal::Stream> = None;
        let mut active_speaker_device_name: Option<String> = None;

        let mut speakers_prod: Option<HeapProd<i16>> = None;
        let mut vmic_prod: Option<HeapProd<i16>> = None;

        let mut last_speaker_fail: Option<Instant> = None;
        let mut last_virtual_mic_fail: Option<Instant> = None;

        let mut last_report = Instant::now();
        let mut bytes_since_last_report = 0;

        loop {
            let is_connected = is_client_connected.load(Ordering::SeqCst);

            if !is_connected {
                if stats.status != "Stopped" {
                    stats.status = "Stopped";
                    stats.packets = 0;
                    stats.bytes_received = 0;
                    stats.last_packet_time = None;
                    
                    speaker_stream = None;
                    virtual_mic_stream = None;
                    active_speaker_device_name = None;
                    speakers_prod = None;
                    vmic_prod = None;
                    println!("Client disconnected. Playout streams dropped.");

                    let stats_payload = serde_json::json!({
                        "status": "Stopped",
                        "bitrate": 0.0,
                        "packets": 0,
                        "latency": 0,
                    });
                    let _ = app_handle.emit("audio-stats", stats_payload.to_string());
                }
                thread::sleep(Duration::from_millis(200));
                continue;
            }

            let desired_speakers = routing_config.enable_speakers.load(Ordering::SeqCst);
            let desired_virtual_mic = routing_config.enable_virtual_mic.load(Ordering::SeqCst);

            match socket.recv_from(&mut buf) {
                Ok((n, _src)) => {
                    if stats.status == "Stopped" || stats.status == "Timeout" || stats.status == "Waiting" {
                        stats.status = "Receiving";
                    }

                    if stats.status == "Receiving" {
                        // 1. Manage Speaker Stream
                        if desired_speakers && speaker_stream.is_none() {
                            let should_retry = match last_speaker_fail {
                                Some(instant) => instant.elapsed() > Duration::from_secs(3),
                                None => true,
                            };
                            if should_retry {
                                let (prod, cons) = HeapRb::<i16>::new(9600).split();
                                speakers_prod = Some(prod);
                                speaker_stream = start_audio_playback(cons, PlayoutTarget::Speakers);
                                if speaker_stream.is_some() {
                                    let host = cpal::default_host();
                                    active_speaker_device_name = host.default_output_device().and_then(|d| d.name().ok());
                                    last_speaker_fail = None;
                                } else {
                                    speakers_prod = None;
                                    last_speaker_fail = Some(Instant::now());
                                    let _ = app_handle.emit("audio-error", "Default speakers not found.");
                                }
                            }
                        } else if !desired_speakers && speaker_stream.is_some() {
                            speaker_stream = None;
                            speakers_prod = None;
                            active_speaker_device_name = None;
                        }

                        // 2. Manage Virtual Mic Stream
                        if desired_virtual_mic && virtual_mic_stream.is_none() {
                            let should_retry = match last_virtual_mic_fail {
                                Some(instant) => instant.elapsed() > Duration::from_secs(3),
                                None => true,
                            };
                            if should_retry {
                                let (prod, cons) = HeapRb::<i16>::new(9600).split();
                                vmic_prod = Some(prod);
                                virtual_mic_stream = start_audio_playback(cons, PlayoutTarget::VirtualMic);
                                if virtual_mic_stream.is_some() {
                                    last_virtual_mic_fail = None;
                                } else {
                                    vmic_prod = None;
                                    last_virtual_mic_fail = Some(Instant::now());
                                    let _ = app_handle.emit("audio-error", "Virtual Mic device (AirMic Speaker / CABLE Input) not found.");
                                }
                            }
                        } else if !desired_virtual_mic && virtual_mic_stream.is_some() {
                            virtual_mic_stream = None;
                            vmic_prod = None;
                        }
                    }

                    stats.packets += 1;
                    stats.bytes_received += n as u64;
                    bytes_since_last_report += n as u64;
                    stats.last_packet_time = Some(Instant::now());
                    
                    transfer_stats.total_mic_bytes.fetch_add(n as u64, Ordering::Relaxed);

                    let mut samples = Vec::with_capacity(n / 2);
                    for chunk in buf[..n].chunks_exact(2) {
                        let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
                        samples.push(sample);
                    }

                    if let Some(ref mut prod) = speakers_prod {
                        let _ = prod.push_slice(&samples);
                    }
                    if let Some(ref mut prod) = vmic_prod {
                        let _ = prod.push_slice(&samples);
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {
                    if stats.status == "Receiving" {
                        if let Some(last_time) = stats.last_packet_time {
                            if last_time.elapsed() > Duration::from_millis(1500) {
                                stats.status = "Timeout";
                                speaker_stream = None;
                                virtual_mic_stream = None;
                                active_speaker_device_name = None;
                                speakers_prod = None;
                                vmic_prod = None;
                                println!("Audio stream timed out. Playout streams dropped.");

                                let stats_payload = serde_json::json!({
                                    "status": "Timeout",
                                    "bitrate": 0.0,
                                    "packets": 0,
                                    "latency": 0,
                                });
                                let _ = app_handle.emit("audio-stats", stats_payload.to_string());
                            }
                        }
                    } else if stats.status == "Stopped" {
                        stats.status = "Waiting";
                    }
                }
                Err(e) => {
                    eprintln!("UDP Playout receive error: {}", e);
                }
            }

            let now = Instant::now();
            if now.duration_since(last_report) >= Duration::from_millis(500) {
                let bitrate = if stats.status == "Receiving" {
                    let elapsed_sec = now.duration_since(last_report).as_secs_f64();
                    (bytes_since_last_report as f64 * 8.0) / (elapsed_sec * 1024.0)
                } else {
                    0.0
                };

                if desired_speakers && speaker_stream.is_some() {
                    let host = cpal::default_host();
                    let current_default_name = host.default_output_device().and_then(|d| d.name().ok());
                    if current_default_name != active_speaker_device_name {
                        println!(
                            "Default audio device changed from {:?} to {:?}. Re-routing stream...",
                            active_speaker_device_name, current_default_name
                        );
                        speaker_stream = None;
                        speakers_prod = None;
                        active_speaker_device_name = current_default_name;
                    }
                }

                let queue_len = speakers_prod.as_ref().map(|p| p.occupied_len()).unwrap_or(0)
                    .max(vmic_prod.as_ref().map(|p| p.occupied_len()).unwrap_or(0));
                let latency_estimate_ms = (queue_len as f64 / 48000.0) * 1000.0;

                let mic_bytes = transfer_stats.total_mic_bytes.load(Ordering::Relaxed);
                let speaker_bytes = transfer_stats.total_speaker_bytes.load(Ordering::Relaxed);
                let speaker_active = speaker_state.is_streaming.load(Ordering::SeqCst);

                let stats_payload = serde_json::json!({
                    "status": stats.status,
                    "bitrate": bitrate,
                    "packets": stats.packets,
                    "latency": latency_estimate_ms as u64,
                    "micBytes": mic_bytes,
                    "speakerBytes": speaker_bytes,
                    "speakerActive": speaker_active,
                });

                let _ = app_handle.emit("audio-stats", stats_payload.to_string());

                last_report = now;
                bytes_since_last_report = 0;
            }
        }
    });
}

fn start_udp_broadcaster(app_handle: AppHandle, pairing_state: Arc<Mutex<PairingState>>) {
    thread::spawn(move || {
        let socket = match UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to bind UDP broadcaster socket: {}", e);
                return;
            }
        };
        socket.set_broadcast(true).ok();

        println!("UDP Broadcaster started on port 9092.");

        loop {
            let pairing_code;
            let device_name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows-PC".to_string());

            {
                let mut state = pairing_state.lock().unwrap();
                // Check if OTP has expired (5 minutes = 300 seconds)
                if state.otp_expiry.elapsed() >= Duration::from_secs(300) {
                    let new_otp = generate_6_digit_otp();
                    println!("Pairing code expired. Generated new code: {}", new_otp);
                    state.active_otp = new_otp.clone();
                    state.otp_expiry = Instant::now();
                    let _ = app_handle.emit("pairing-code-changed", &state.active_otp);
                }
                pairing_code = state.active_otp.clone();
            }

            let ip = get_local_ip();

            let payload = serde_json::json!({
                "service": "AIRMIC",
                "code": pairing_code,
                "device_name": device_name,
                "ip": ip,
                "control_port": 9090
            });

            let payload_str = payload.to_string();
            let _ = socket.send_to(payload_str.as_bytes(), "255.255.255.255:9092");

            thread::sleep(Duration::from_secs(2));
        }
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let is_client_connected = Arc::new(AtomicBool::new(false));
    let routing_config = Arc::new(AudioRoutingConfig {
        enable_speakers: AtomicBool::new(true),
        enable_virtual_mic: AtomicBool::new(false),
    });

    let transfer_stats = Arc::new(TransferStats {
        total_mic_bytes: AtomicU64::new(0),
        total_speaker_bytes: AtomicU64::new(0),
    });

    let tray_config = Arc::new(TrayConfig {
        minimize_to_tray: AtomicBool::new(true),
    });

    let paired_ids = load_paired_devices();
    let active_otp = generate_6_digit_otp();
    let pairing_state = Arc::new(Mutex::new(PairingState {
        active_otp,
        otp_expiry: Instant::now(),
        paired_identifiers: paired_ids,
    }));

    let phone_ip_state = Arc::new(ConnectedPhoneIp {
        ip: Mutex::new(String::new()),
    });

    let speaker_state = Arc::new(SpeakerStreamState {
        is_streaming: AtomicBool::new(false),
        handle: Mutex::new(None),
    });

    let connected_udp = is_client_connected.clone();
    let connected_tcp = is_client_connected.clone();
    let routing_udp = routing_config.clone();
    let stats_tcp = transfer_stats.clone();
    let stats_udp = transfer_stats.clone();
    let pairing_tcp = pairing_state.clone();
    let pairing_broadcaster = pairing_state.clone();
    let phone_tcp = phone_ip_state.clone();
    let speaker_tcp = speaker_state.clone();
    let speaker_udp = speaker_state.clone();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(routing_config)
        .manage(pairing_state.clone())
        .manage(phone_ip_state)
        .manage(speaker_state)
        .manage(transfer_stats)
        .manage(tray_config.clone())
        .setup(move |app| {
            let handle = app.handle().clone();
            
            // Build the system tray menu and icon in Tauri v2
            let toggle_show = tauri::menu::MenuItem::with_id(app, "toggle_show", "Show Window", true, None::<&str>)?;
            let quit = tauri::menu::MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = tauri::menu::Menu::with_items(app, &[&toggle_show, &quit])?;

            let icon_bytes = include_bytes!("../icons/32x32.png");
            let icon = tauri::image::Image::from_bytes(icon_bytes).expect("Failed to load tray icon");

            let _tray = tauri::tray::TrayIconBuilder::new()
                .icon(icon)
                .menu(&menu)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle_show" => {
                        if let Some(w) = app.get_webview_window("main") {
                            let _ = w.show();
                            let _ = w.set_focus();
                        }
                    }
                    "quit" => {
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::Click { button: tauri::tray::MouseButton::Left, .. } = event {
                        let app = tray.app_handle();
                        if let Some(w) = app.get_webview_window("main") {
                            if w.is_visible().unwrap_or(false) {
                                let _ = w.hide();
                            } else {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                    }
                })
                .build(app)?;

            // Register window close-requested event listener to hide instead of exit when toggled
            let window = app.get_webview_window("main").unwrap();
            let app_handle_for_close = app.handle().clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    let minimize_state = app_handle_for_close.state::<Arc<TrayConfig>>();
                    if minimize_state.minimize_to_tray.load(Ordering::SeqCst) {
                        api.prevent_close();
                        let _ = app_handle_for_close.get_webview_window("main").unwrap().hide();
                    }
                }
            });

            // Start TCP, UDP playout, and UDP broadcast threads
            start_tcp_listener(handle.clone(), connected_tcp, pairing_tcp, phone_tcp, speaker_tcp, stats_tcp);
            start_udp_listener(handle.clone(), connected_udp, routing_udp, stats_udp, speaker_udp);
            start_udp_broadcaster(handle, pairing_broadcaster);
            
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_local_ip,
            get_driver_status,
            update_audio_routing,
            get_pairing_code,
            regenerate_pairing_code,
            start_speaker_stream,
            stop_speaker_stream,
            update_tray_config
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
