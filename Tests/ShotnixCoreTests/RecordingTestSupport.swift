import AVFoundation
import CoreMedia
import XCTest
@testable import ShotnixCore

/// Sample buffers stamped with host-clock times, the way ScreenCaptureKit
/// and the microphone deliver them, plus readers for what got written.
enum RecordingTestBuffers {
    static func video(at host: Double, width: Int = 64, height: Int = 36, shade: UInt8 = 128) -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: host, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample!
    }

    static func audioFormat(channels: Int, planar: Bool, rate: Double = 48_000) -> CMAudioFormatDescription {
        var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        let bytesPerFrame = UInt32(planar ? 4 : 4 * channels)
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        return format!
    }

    /// `value(t)` gives the sample at host time t (same value on every channel).
    static func audio(at host: Double, frames: Int, channels: Int, planar: Bool, rate: Double = 48_000, value: (Double) -> Float) -> CMSampleBuffer {
        let format = audioFormat(channels: channels, planar: planar, rate: rate)
        let planes = planar ? channels : 1
        let perPlane = planar ? 1 : channels
        let storage = (0..<planes).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames * perPlane) }
        defer { storage.forEach { $0.deallocate() } }
        for frame in 0..<frames {
            let sample = value(host + Double(frame) / rate)
            for plane in 0..<planes {
                for channel in 0..<perPlane { storage[plane][frame * perPlane + channel] = sample }
            }
        }
        let list = AudioBufferList.allocate(maximumBuffers: planes)
        defer { free(list.unsafeMutablePointer) }
        for plane in 0..<planes {
            list[plane] = AudioBuffer(mNumberChannels: UInt32(perPlane), mDataByteSize: UInt32(frames * perPlane * 4), mData: storage[plane])
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue((host * rate).rounded()), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: list.unsafePointer)
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }

    /// Every channel's samples of a PCM sample buffer, per channel.
    static func channels(of buffer: CMSampleBuffer) -> [[Float]] {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return [] }
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(buffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        let list = UnsafeMutableAudioBufferListPointer(listPointer)
        let frames = CMSampleBufferGetNumSamples(buffer)
        let planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var result: [[Float]] = []
        for audioBuffer in list {
            let values = audioBuffer.mData!.assumingMemoryBound(to: Float.self)
            let perPlane = planar ? 1 : Int(description.mChannelsPerFrame)
            for channel in 0..<perPlane {
                result.append((0..<frames).map { values[$0 * perPlane + channel] })
            }
        }
        return result
    }

    /// The file's audio track as mono float samples at 48 kHz.
    static func decodeAudio(_ url: URL, track index: Int = 0) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    /// Start times of loud stretches (5 ms windows above `threshold` RMS).
    static func onsets(in samples: [Float], rate: Double = 48_000, threshold: Float = 0.1) -> [Double] {
        let window = Int(rate * 0.005)
        var onsets: [Double] = []
        var loud = false
        var start = 0
        while start + window <= samples.count {
            let slice = samples[start..<(start + window)]
            let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(window)).squareRoot()
            if rms > threshold, !loud { onsets.append(Double(start) / rate) }
            loud = rms > threshold
            start += window
        }
        return onsets
    }

    static func videoFrameTimes(_ url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let buffer = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(buffer) > 0 { times.append(buffer.presentationTimeStamp.seconds) }
        }
        return times.sorted()
    }

    static func waitUntilReady(_ input: AVAssetWriterInput?) {
        guard let input else { return }
        let deadline = Date().addingTimeInterval(2)
        while !input.isReadyForMoreMediaData, Date() < deadline { usleep(1_000) }
    }
}
