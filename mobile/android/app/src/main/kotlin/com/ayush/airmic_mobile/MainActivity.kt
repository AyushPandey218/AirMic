package com.ayush.airmic_mobile

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentLinkedQueue

class MainActivity: FlutterActivity() {
    private val TAG = "AirMic"
    private val BLUETOOTH_CHANNEL = "com.ayush.airmic/bluetooth"
    private val SPEAKER_CHANNEL = "com.ayush.airmic/speaker"
    private var channel: MethodChannel? = null

    // Speaker Playout (PC -> Phone) variables
    private var speakerTrack: AudioTrack? = null
    private var speakerSocket: DatagramSocket? = null
    private var isSpeakerRunning = false
    private var speakerThread: Thread? = null

    // Microphone Capture (Phone -> PC) variables
    private var audioRecord: AudioRecord? = null
    private var micSocket: DatagramSocket? = null
    private var isMicRunning = false
    private var micThread: Thread? = null
    private var selectedMicDeviceId: Int? = null

    private var audioManager: AudioManager? = null
    private var isScoStarted = false
    private var scoState = AudioManager.SCO_AUDIO_STATE_DISCONNECTED

    private val scoReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val state = intent.getIntExtra(AudioManager.EXTRA_SCO_AUDIO_STATE, -1)
            Log.i(TAG, "SCO audio state updated: $state")
            scoState = state
            
            val stateStr = when (state) {
                AudioManager.SCO_AUDIO_STATE_CONNECTED -> "connected"
                AudioManager.SCO_AUDIO_STATE_DISCONNECTED -> "disconnected"
                AudioManager.SCO_AUDIO_STATE_ERROR -> "error"
                else -> "connecting"
            }
            runOnUiThread {
                channel?.invokeMethod("onScoStateChanged", stateStr)
            }
        }
    }

    private val audioDeviceCallback = object : android.media.AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            super.onAudioDevicesAdded(addedDevices)
            runOnUiThread {
                channel?.invokeMethod("onDevicesChanged", null)
            }
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            super.onAudioDevicesRemoved(removedDevices)
            runOnUiThread {
                channel?.invokeMethod("onDevicesChanged", null)
            }
        }
    }

    private val BLUETOOTH_CONNECT_REQ_CODE = 101

    private fun checkAndRequestBluetoothPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                Log.i(TAG, "Requesting BLUETOOTH_CONNECT permission...")
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), BLUETOOTH_CONNECT_REQ_CODE)
                return false
            }
        }
        return true
    }

    private fun setupScoRouting(enable: Boolean): Boolean {
        val am = audioManager ?: return false
        Log.i(TAG, "setupScoRouting: $enable")
        try {
            if (enable) {
                if (!checkAndRequestBluetoothPermission()) {
                    Log.w(TAG, "BLUETOOTH_CONNECT permission not granted yet")
                    return false
                }
                if (isScoStarted) return true
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val devices = am.availableCommunicationDevices
                    val bluetoothDevice = devices.firstOrNull { 
                        it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || 
                        it.type == AudioDeviceInfo.TYPE_BLE_HEADSET 
                    }
                    if (bluetoothDevice != null) {
                        val success = am.setCommunicationDevice(bluetoothDevice)
                        Log.i(TAG, "setCommunicationDevice (${bluetoothDevice.type}) success: $success")
                        isScoStarted = success
                        return success
                    } else {
                        Log.w(TAG, "No Bluetooth communication device found, calling startBluetoothSco fallback")
                        am.startBluetoothSco()
                        am.isBluetoothScoOn = true
                        isScoStarted = true
                        return true
                    }
                } else {
                    am.startBluetoothSco()
                    am.isBluetoothScoOn = true
                    isScoStarted = true
                    return true
                }
            } else {
                if (!isScoStarted) return true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    am.clearCommunicationDevice()
                }
                am.isBluetoothScoOn = false
                am.stopBluetoothSco()
                am.mode = AudioManager.MODE_NORMAL
                isScoStarted = false
                return true
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in setupScoRouting", e)
            return false
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        checkAndRequestBluetoothPermission()

        // Register BroadcastReceiver for SCO audio state updates
        val filter = IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED)
        registerReceiver(scoReceiver, filter)

        // Register AudioDeviceCallback
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager?.registerAudioDeviceCallback(audioDeviceCallback, null)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BLUETOOTH_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startBluetoothSco" -> {
                    val success = setupScoRouting(true)
                    result.success(success)
                }
                "stopBluetoothSco" -> {
                    val success = setupScoRouting(false)
                    result.success(success)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        val mChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEAKER_CHANNEL)
        channel = mChannel
        mChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startAudioStream" -> {
                    val pcIp = call.argument<String>("pcIp")
                    val isBluetooth = call.argument<Boolean>("isBluetooth") ?: false
                    val enableSpeakers = call.argument<Boolean>("enableSpeakers") ?: true
                    val enableMic = call.argument<Boolean>("enableMic") ?: false
                    val inputDeviceIdStr = call.argument<String>("selectedMicDeviceId")

                    Log.i(TAG, "startAudioStream invoked: pcIp=$pcIp, isBluetooth=$isBluetooth, enableSpeakers=$enableSpeakers, enableMic=$enableMic, inputDeviceId=$inputDeviceIdStr")

                    selectedMicDeviceId = inputDeviceIdStr?.toIntOrNull()

                    if (pcIp == null) {
                        result.error("INVALID_ARGUMENTS", "PC IP Address is required", null)
                        return@setMethodCallHandler
                    }

                    try {
                        stopAllStreams()

                        if (enableSpeakers) {
                            startSpeakerPlayout(isBluetooth)
                        }
                        if (enableMic) {
                            startMicCapture(pcIp, isBluetooth)
                        }

                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to start audio streams", e)
                        result.error("STREAM_START_FAILED", e.message, null)
                    }
                }
                "stopAudioStream" -> {
                    try {
                        Log.i(TAG, "stopAudioStream invoked")
                        stopAllStreams()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to stop audio streams", e)
                        result.error("STREAM_STOP_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun startSpeakerPlayout(isBluetooth: Boolean) {
        Log.i(TAG, "Initializing speaker playout thread...")
        isSpeakerRunning = true
        speakerThread = Thread {
            var threadSocket: DatagramSocket? = null
            var threadTrack: AudioTrack? = null
            try {
                // Configure socket with reuseAddress to prevent BindExceptions
                val socket = DatagramSocket(null)
                socket.reuseAddress = true
                socket.bind(InetSocketAddress(9093))
                socket.soTimeout = 1000 // 1 second read timeout
                speakerSocket = socket
                threadSocket = socket
                Log.i(TAG, "Playout UDP socket bound successfully to port 9093")

                val sampleRate = 48000
                val channelConfig = AudioFormat.CHANNEL_OUT_STEREO
                val encoding = AudioFormat.ENCODING_PCM_16BIT
                val minBufSize = AudioTrack.getMinBufferSize(sampleRate, channelConfig, encoding)
                val bufferSize = Math.max(minBufSize, 480 * 2 * 2 * 4)

                val trackBuilder = AudioTrack.Builder()
                    .setAudioAttributes(
                        android.media.AudioAttributes.Builder()
                            .setUsage(if (isBluetooth) android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION else android.media.AudioAttributes.USAGE_MEDIA)
                            .setContentType(if (isBluetooth) android.media.AudioAttributes.CONTENT_TYPE_SPEECH else android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(encoding)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelConfig)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    trackBuilder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                }
                val track = trackBuilder.build()
                speakerTrack = track
                threadTrack = track
                track.play()
                Log.i(TAG, "AudioTrack playing in low-latency mode")

                val packetBuf = ByteArray(65536)
                val queue = ConcurrentLinkedQueue<ByteArray>()

                var targetDelay = 2 // packets
                var isBuffering = true
                var consecutiveSuccess = 0
                var isPlaying = false
                var speakerPacketCount = 0L
                var speakerBytesReceived = 0L
                var speakerFrameCount = 0

                while (isSpeakerRunning) {
                    try {
                        val packet = DatagramPacket(packetBuf, packetBuf.size)
                        socket.receive(packet)
                        val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)

                        speakerPacketCount++
                        speakerBytesReceived += data.size
                        speakerFrameCount++

                        if (!isPlaying) {
                            isPlaying = true
                            Log.i(TAG, "First packet received on UDP 9093 - transitioning status to receiving")
                            runOnUiThread {
                                channel?.invokeMethod("onSpeakerStatusChanged", true)
                            }
                        }

                        if (speakerFrameCount >= 100) {
                            speakerFrameCount = 0
                            val spCount = speakerPacketCount
                            val sbReceived = speakerBytesReceived
                            runOnUiThread {
                                val map = HashMap<String, Long>()
                                map["packets"] = spCount
                                map["bytesReceived"] = sbReceived
                                channel?.invokeMethod("onSpeakerStats", map)
                            }
                        }

                        queue.add(data)

                        if (queue.size > targetDelay + 2) {
                            queue.poll() // Discard oldest packet to catch up latency
                        }

                        if (isBuffering) {
                            if (queue.size >= targetDelay) {
                                isBuffering = false
                            }
                        }

                        if (!isBuffering) {
                            val nextData = queue.poll()
                            if (nextData != null) {
                                track.write(nextData, 0, nextData.size)
                                consecutiveSuccess++
                                if (consecutiveSuccess >= 300) {
                                    if (targetDelay > 2) {
                                        targetDelay--
                                    }
                                    consecutiveSuccess = 0
                                }
                            } else {
                                isBuffering = true
                                if (targetDelay < 6) {
                                    targetDelay++
                                }
                                consecutiveSuccess = 0
                            }
                        }
                    } catch (e: java.io.InterruptedIOException) {
                        // Receive timeout
                        isBuffering = true
                        consecutiveSuccess = 0
                        if (isPlaying) {
                            isPlaying = false
                            Log.i(TAG, "UDP read timeout (no audio packets received) - notifying UI")
                            runOnUiThread {
                                channel?.invokeMethod("onSpeakerStatusChanged", false)
                            }
                        }
                    } catch (e: java.net.SocketException) {
                        Log.i(TAG, "Playout socket closed normally: ${e.message}")
                    } catch (e: Exception) {
                        Log.e(TAG, "Playout loop error", e)
                    }
                }

                try {
                    track.stop()
                    track.release()
                } catch (e: Exception) {}
            } catch (e: Exception) {
                Log.e(TAG, "Playout thread initialization error", e)
            } finally {
                threadTrack?.let {
                    try {
                        it.stop()
                        it.release()
                    } catch (_: Exception) {}
                }
                speakerTrack = null
                threadSocket?.close()
                speakerSocket = null
                Log.i(TAG, "Playout socket closed")
            }
        }
        speakerThread?.start()
    }

    private fun startMicCapture(pcIp: String, isBluetooth: Boolean) {
        Log.i(TAG, "Initializing microphone capture thread...")
        isMicRunning = true
        micThread = Thread {
            var threadSocket: DatagramSocket? = null
            var threadRecorder: AudioRecord? = null
            try {
                val socket = DatagramSocket()
                threadSocket = socket
                micSocket = socket

                val sampleRate = if (isBluetooth) 16000 else 48000
                val channelConfig = AudioFormat.CHANNEL_IN_MONO
                val encoding = AudioFormat.ENCODING_PCM_16BIT
                val minBufSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, encoding)
                val bufferSize = Math.max(minBufSize, 480 * 2 * 4)

                val recorder = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    sampleRate,
                    channelConfig,
                    encoding,
                    bufferSize
                )
                audioRecord = recorder
                threadRecorder = recorder

                if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                    Log.e(TAG, "AudioRecord state was not initialized")
                    return@Thread
                }

                // Route to user-selected input device if one is chosen (API 23+).
                // For Bluetooth devices, skip setPreferredDevice — the active Bluetooth SCO
                // (/CommunicationDevice) already routes VOICE_COMMUNICATION capture to the
                // Bluetooth headset automatically. Calling setPreferredDevice on top of SCO
                // routing can cause a silent AudioRecord.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && selectedMicDeviceId != null) {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val devices = audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
                    val matchedDevice = devices.find { it.id == selectedMicDeviceId }
                    if (matchedDevice != null) {
                        val isBluetooth = matchedDevice.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        Log.i(TAG, "Found device: ${matchedDevice.productName} (id=${matchedDevice.id}) type=${matchedDevice.type} bluetooth=$isBluetooth")
                        if (isBluetooth) {
                            Log.i(TAG, "Bluetooth device — relying on SCO routing, skipping setPreferredDevice")
                        } else {
                            if (!recorder.setPreferredDevice(matchedDevice)) {
                                Log.w(TAG, "setPreferredDevice returned false for ${matchedDevice.productName}")
                            } else {
                                Log.i(TAG, "AudioRecord routed to selected device: ${matchedDevice.productName}")
                            }
                        }
                    } else {
                        Log.w(TAG, "Selected device id $selectedMicDeviceId not found among available inputs. Available devices: ${devices.map { "${it.id}:${it.productName}" }}")
                    }
                }

                recorder.startRecording()
                Log.i(TAG, "AudioRecord capturing live microphone audio")

                val inetAddress = InetAddress.getByName(pcIp)
                val frameSizeSamples = if (isBluetooth) 160 else 480
                val readBuffer = ShortArray(frameSizeSamples)

                var micPacketCount = 0L
                var micBytesSent = 0L
                val statsFrameInterval = if (isBluetooth) 100 else 50
                var frameCounter = 0

                while (isMicRunning) {
                    val readResult = recorder.read(readBuffer, 0, frameSizeSamples)
                    if (readResult > 0) {
                        val pcmData = ByteArray(readResult * 2)
                        ByteBuffer.wrap(pcmData).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().put(readBuffer, 0, readResult)

                        val dataToSend = if (isBluetooth) {
                            val upsampled = ByteArray(pcmData.size * 3)
                            var destIdx = 0
                            for (i in 0 until readResult) {
                                val s1 = pcmData[i * 2]
                                val s2 = pcmData[i * 2 + 1]
                                for (j in 0 until 3) {
                                    upsampled[destIdx++] = s1
                                    upsampled[destIdx++] = s2
                                }
                            }
                            upsampled
                        } else {
                            pcmData
                        }

                        val packet = DatagramPacket(dataToSend, dataToSend.size, inetAddress, 9091)
                        socket.send(packet)

                        micPacketCount++
                        micBytesSent += dataToSend.size
                        frameCounter++

                        if (frameCounter >= statsFrameInterval) {
                            frameCounter = 0
                            val pCount = micPacketCount
                            val bSent = micBytesSent
                            runOnUiThread {
                                val map = HashMap<String, Long>()
                                map["packetsSent"] = pCount
                                map["bytesSent"] = bSent
                                channel?.invokeMethod("onMicStats", map)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                if (!e.message?.contains("Socket is closed")!! && !e.message?.contains("socket closed")!!) {
                    Log.e(TAG, "Microphone capture thread error", e)
                }
            } finally {
                threadRecorder?.let {
                    try {
                        it.stop()
                        it.release()
                    } catch (_: Exception) {}
                }
                audioRecord = null
                threadSocket?.close()
                micSocket = null
                Log.i(TAG, "Capture socket closed")
            }
        }
        micThread?.start()
    }

    private fun stopAllStreams() {
        Log.i(TAG, "stopAllStreams: Stopping playout and capture threads")
        
        // Stop speaker playout
        isSpeakerRunning = false
        speakerSocket?.close()
        speakerThread?.interrupt()
        speakerThread = null
        speakerTrack = null

        runOnUiThread {
            Log.i(TAG, "stopAllStreams: notifying status false to UI")
            channel?.invokeMethod("onSpeakerStatusChanged", false)
        }

        // Stop mic capture
        isMicRunning = false
        audioRecord?.let {
            try {
                it.stop()
                it.release()
            } catch (e: Exception) {}
        }
        audioRecord = null
        micSocket?.close()
        micThread?.interrupt()
        micThread = null
    }

    override fun onDestroy() {
        stopAllStreams()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager?.unregisterAudioDeviceCallback(audioDeviceCallback)
        }
        try {
            unregisterReceiver(scoReceiver)
        } catch (e: Exception) {}
        super.onDestroy()
    }
}
