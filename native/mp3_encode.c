#include "record-bridging.h"

#include "layer3.h"

#include <AudioToolbox/AudioToolbox.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int closest_supported_sample_rate(int rate) {
    static const int rates[] = {48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000};
    int best = 44100;
    int best_diff = abs(rate - best);
    for (size_t index = 0; index < sizeof(rates) / sizeof(rates[0]); index += 1) {
        int diff = abs(rate - rates[index]);
        if (diff < best_diff) {
            best = rates[index];
            best_diff = diff;
        }
    }
    return best;
}

static int choose_bitrate(int sample_rate, int channels) {
    int bitrate = channels > 1 ? 192 : 128;
    if (shine_check_config(sample_rate, bitrate) >= 0) {
        return bitrate;
    }
    return 128;
}

int record_encode_audio_file_to_mp3(const char *input_path, const char *output_path) {
    if (input_path == NULL || output_path == NULL) {
        return -1;
    }

    CFURLRef input_url = CFURLCreateFromFileSystemRepresentation(
        kCFAllocatorDefault,
        (const UInt8 *)input_path,
        (CFIndex)strlen(input_path),
        false
    );
    if (input_url == NULL) {
        return -1;
    }

    ExtAudioFileRef audio_file = NULL;
    OSStatus status = ExtAudioFileOpenURL(input_url, &audio_file);
    CFRelease(input_url);
    if (status != noErr || audio_file == NULL) {
        return -1;
    }

    AudioStreamBasicDescription file_format = {0};
    UInt32 property_size = sizeof(file_format);
    status = ExtAudioFileGetProperty(
        audio_file,
        kExtAudioFileProperty_FileDataFormat,
        &property_size,
        &file_format
    );
    if (status != noErr || file_format.mSampleRate <= 0) {
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    AudioStreamBasicDescription client_format = {0};
    client_format.mSampleRate = closest_supported_sample_rate((int)file_format.mSampleRate);
    client_format.mFormatID = kAudioFormatLinearPCM;
    client_format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    client_format.mBitsPerChannel = 16;
    client_format.mChannelsPerFrame = file_format.mChannelsPerFrame >= 2 ? 2 : 1;
    client_format.mFramesPerPacket = 1;
    client_format.mBytesPerFrame = 2 * client_format.mChannelsPerFrame;
    client_format.mBytesPerPacket = client_format.mBytesPerFrame;

    status = ExtAudioFileSetProperty(
        audio_file,
        kExtAudioFileProperty_ClientDataFormat,
        sizeof(client_format),
        &client_format
    );
    if (status != noErr) {
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    shine_config_t config;
    memset(&config, 0, sizeof(config));
    config.wave.channels = client_format.mChannelsPerFrame == 2 ? PCM_STEREO : PCM_MONO;
    config.wave.samplerate = (int)client_format.mSampleRate;
    shine_set_config_mpeg_defaults(&config.mpeg);
    config.mpeg.mode = client_format.mChannelsPerFrame == 2 ? JOINT_STEREO : MONO;
    config.mpeg.bitr = choose_bitrate(config.wave.samplerate, (int)client_format.mChannelsPerFrame);
    if (shine_check_config(config.wave.samplerate, config.mpeg.bitr) < 0) {
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    shine_t encoder = shine_initialise(&config);
    if (encoder == NULL) {
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    char temp_path[PATH_MAX];
    if (snprintf(temp_path, sizeof(temp_path), "%s.part", output_path) >= (int)sizeof(temp_path)) {
        shine_close(encoder);
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    FILE *output = fopen(temp_path, "wb");
    if (output == NULL) {
        shine_close(encoder);
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    int samples_per_pass = shine_samples_per_pass(encoder);
    int channels = (int)client_format.mChannelsPerFrame;
    int16_t *pcm = calloc((size_t)samples_per_pass * (size_t)channels, sizeof(int16_t));
    if (pcm == NULL) {
        fclose(output);
        shine_close(encoder);
        ExtAudioFileDispose(audio_file);
        return -1;
    }

    int result = 0;
    while (1) {
        AudioBufferList buffer_list;
        buffer_list.mNumberBuffers = 1;
        buffer_list.mBuffers[0].mNumberChannels = (UInt32)channels;
        buffer_list.mBuffers[0].mDataByteSize = (UInt32)(samples_per_pass * channels * (int)sizeof(int16_t));
        buffer_list.mBuffers[0].mData = pcm;

        UInt32 frame_count = (UInt32)samples_per_pass;
        memset(pcm, 0, (size_t)samples_per_pass * (size_t)channels * sizeof(int16_t));
        status = ExtAudioFileRead(audio_file, &frame_count, &buffer_list);
        if (status != noErr) {
            result = -1;
            break;
        }
        if (frame_count == 0) {
            break;
        }

        int written = 0;
        unsigned char *encoded = shine_encode_buffer_interleaved(encoder, pcm, &written);
        if (written > 0 && encoded != NULL) {
            if (fwrite(encoded, 1, (size_t)written, output) != (size_t)written) {
                result = -1;
                break;
            }
        }

        if (frame_count < (UInt32)samples_per_pass) {
            break;
        }
    }

    if (result == 0) {
        int written = 0;
        unsigned char *encoded = shine_flush(encoder, &written);
        if (written > 0 && encoded != NULL) {
            if (fwrite(encoded, 1, (size_t)written, output) != (size_t)written) {
                result = -1;
            }
        }
    }

    free(pcm);
    fclose(output);
    shine_close(encoder);
    ExtAudioFileDispose(audio_file);

    if (result == 0 && rename(temp_path, output_path) != 0) {
        result = -1;
    }
    if (result != 0) {
        remove(temp_path);
        remove(output_path);
    }

    return result;
}
