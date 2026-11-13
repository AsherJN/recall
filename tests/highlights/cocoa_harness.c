/*
 * Drives winemacmf's macOS half directly, without Wine: encodes a moving
 * test pattern and a two-tone sine, writes them into an MPEG-4 file the way
 * the Media Foundation sink does, and leaves the file for verify_mp4.swift.
 *
 *   cocoa_harness <out.mp4> <bgra|nv12|i420|yv12|yuy2> [width height fps seconds]
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "macmf_cocoa.h"

#define TIMESCALE 10000000LL

void macmf_log_error(const char *message) { fprintf(stderr, "error: %s\n", message); }
void macmf_log_trace(const char *message) { fprintf(stderr, "trace: %s\n", message); }

/* Eight vertical bars that move right by 8 pixels a frame; the frame number is
 * written in binary into the top-left 32 blocks (white = 1). */
static const uint8_t bars[8][3] = {
    {235, 235, 235}, {235, 235, 16}, {16, 235, 235}, {16, 235, 16},
    {235, 16, 235}, {235, 16, 16}, {16, 16, 235}, {16, 16, 16},
};

static void pattern_rgb(unsigned int width, unsigned int height, unsigned int frame,
        unsigned int x, unsigned int y, uint8_t rgb[3])
{
    unsigned int bar = ((x + width - (frame * 8) % width) % width) * 8 / width;

    if (y < 16 && x < 32 * 16)
    {
        unsigned int bit = (frame >> (x / 16)) & 1;
        rgb[0] = rgb[1] = rgb[2] = bit ? 235 : 16;
        return;
    }
    memcpy(rgb, bars[bar], 3);
}

static void rgb_to_yuv(const uint8_t rgb[3], uint8_t *y, uint8_t *u, uint8_t *v)
{
    /* BT.709, video range, from video-range RGB values. */
    double r = (rgb[0] - 16) / 219.0, g = (rgb[1] - 16) / 219.0, b = (rgb[2] - 16) / 219.0;
    double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    *y = (uint8_t)lround(16 + 219 * luma);
    *u = (uint8_t)lround(128 + 224 * (b - luma) / 1.8556);
    *v = (uint8_t)lround(128 + 224 * (r - luma) / 1.5748);
}

static uint8_t *make_frame(const char *format, unsigned int width, unsigned int height, unsigned int frame,
        int64_t *stride, size_t *size)
{
    unsigned int x, y, cw = width / 2, ch = height / 2;
    uint8_t rgb[3], Y, U, V, *data, *py, *pu, *pv;

    if (!strcmp(format, "bgra"))
    {
        *stride = (int64_t)width * 4;
        *size = (size_t)*stride * height;
        data = malloc(*size);
        for (y = 0; y < height; ++y)
            for (x = 0; x < width; ++x)
            {
                uint8_t *p = data + y * *stride + x * 4;
                pattern_rgb(width, height, frame, x, y, rgb);
                p[0] = rgb[2]; p[1] = rgb[1]; p[2] = rgb[0]; p[3] = 255;
            }
        return data;
    }
    if (!strcmp(format, "yuy2"))
    {
        *stride = (int64_t)width * 2;
        *size = (size_t)*stride * height;
        data = malloc(*size);
        for (y = 0; y < height; ++y)
            for (x = 0; x < width; x += 2)
            {
                uint8_t *p = data + y * *stride + x * 2, Y2, U2, V2;
                pattern_rgb(width, height, frame, x, y, rgb);
                rgb_to_yuv(rgb, &Y, &U, &V);
                pattern_rgb(width, height, frame, x + 1, y, rgb);
                rgb_to_yuv(rgb, &Y2, &U2, &V2);
                p[0] = Y; p[1] = U; p[2] = Y2; p[3] = V;
            }
        return data;
    }

    *stride = width;
    *size = (size_t)width * height * 3 / 2;
    data = malloc(*size);
    py = data;
    if (!strcmp(format, "nv12"))
    {
        pu = data + (size_t)width * height;
        for (y = 0; y < height; ++y)
            for (x = 0; x < width; ++x)
            {
                pattern_rgb(width, height, frame, x, y, rgb);
                rgb_to_yuv(rgb, &Y, &U, &V);
                py[y * width + x] = Y;
                if (!(x & 1) && !(y & 1))
                {
                    pu[(y / 2) * width + x] = U;
                    pu[(y / 2) * width + x + 1] = V;
                }
            }
        return data;
    }
    /* i420 / yv12 */
    pu = data + (size_t)width * height;
    pv = pu + (size_t)cw * ch;
    if (!strcmp(format, "yv12"))
    {
        uint8_t *swap = pu;
        pu = pv;
        pv = swap;
    }
    for (y = 0; y < height; ++y)
        for (x = 0; x < width; ++x)
        {
            pattern_rgb(width, height, frame, x, y, rgb);
            rgb_to_yuv(rgb, &Y, &U, &V);
            py[y * width + x] = Y;
            if (!(x & 1) && !(y & 1))
            {
                pu[(y / 2) * cw + x / 2] = U;
                pv[(y / 2) * cw + x / 2] = V;
            }
        }
    return data;
}

struct stored
{
    uint8_t *data;
    struct macmf_packet_info info;
    int track;
};

static struct stored *packets;
static size_t packet_count, packet_capacity;

static void store(uint8_t *data, struct macmf_packet_info *info, int track)
{
    if (packet_count == packet_capacity)
    {
        packet_capacity = packet_capacity ? packet_capacity * 2 : 1024;
        packets = realloc(packets, packet_capacity * sizeof(*packets));
    }
    packets[packet_count].data = data;
    packets[packet_count].info = *info;
    packets[packet_count].track = track;
    packet_count++;
}

static int drain_video(void *encoder)
{
    struct macmf_packet_info info;
    int ret;

    for (;;)
    {
        ret = macmf_video_encoder_read(encoder, NULL, 0, &info);
        if (ret == MACMF_NONE) return 0;
        if (ret != MACMF_TOO_SMALL) return -1;
        uint8_t *data = malloc(info.size);
        if (macmf_video_encoder_read(encoder, data, info.size, &info) != MACMF_OK) return -1;
        store(data, &info, 0);
    }
}

static int64_t audio_first_time;
static unsigned int audio_packets, audio_priming;

static int drain_audio(void *encoder, unsigned int rate)
{
    struct macmf_packet_info info;
    int ret;

    for (;;)
    {
        ret = macmf_audio_encoder_read(encoder, NULL, 0, &info);
        if (ret == MACMF_NONE) return 0;
        if (ret != MACMF_TOO_SMALL) return -1;
        uint8_t *data = malloc(info.size);
        if (macmf_audio_encoder_read(encoder, data, info.size, &info) != MACMF_OK) return -1;
        info.time = audio_first_time + ((int64_t)audio_packets * 1024 - audio_priming) * TIMESCALE / rate;
        info.duration = 1024 * TIMESCALE / rate;
        info.decode_time = info.time;
        audio_packets++;
        store(data, &info, 1);
    }
}

static int by_time(const void *a, const void *b)
{
    const struct stored *x = a, *y = b;
    int64_t tx = x->track ? x->info.time : x->info.decode_time, ty = y->track ? y->info.time : y->info.decode_time;
    return tx < ty ? -1 : tx > ty;
}

int main(int argc, char **argv)
{
    const char *path, *format;
    unsigned int width = 1920, height = 1080, fps = 60, seconds = 3, frames, i, rate = 48000;
    struct macmf_video_settings settings = {0};
    uint8_t config[64], asc[16], buffer[1 << 16];
    uint32_t config_size = 0, asc_size = 0, size;
    void *video, *audio, *muxer;
    int video_track, audio_track, fmt;
    uint64_t total = 0, offset;
    FILE *out;

    if (argc < 3) return 2;
    path = argv[1];
    format = argv[2];
    if (argc >= 7)
    {
        width = atoi(argv[3]);
        height = atoi(argv[4]);
        fps = atoi(argv[5]);
        seconds = atoi(argv[6]);
    }
    frames = fps * seconds;
    fmt = !strcmp(format, "bgra") ? 0 : !strcmp(format, "nv12") ? 1 : !strcmp(format, "i420") ? 2
            : !strcmp(format, "yv12") ? 3 : 4;

    settings.width = width;
    settings.height = height;
    settings.frame_rate_num = fps;
    settings.frame_rate_den = 1;
    settings.format = fmt;
    settings.bitrate = 12000000;
    settings.profile = 100;
    if (!(video = macmf_video_encoder_create(&settings))) return 3;

    for (i = 0; i < frames; ++i)
    {
        int64_t stride;
        size_t frame_size;
        uint8_t *frame = make_frame(format, width, height, i, &stride, &frame_size);
        int64_t time = (int64_t)i * TIMESCALE / fps, next = (int64_t)(i + 1) * TIMESCALE / fps;

        if (macmf_video_encoder_encode(video, frame, stride, frame, frame_size, time, next - time, 0) != MACMF_OK)
            return 4;
        free(frame);
        if (drain_video(video)) return 5;
    }
    if (macmf_video_encoder_drain(video) != MACMF_OK || drain_video(video)) return 6;
    if (macmf_video_encoder_config(video, config, sizeof(config), &config_size) != MACMF_OK) return 7;

    if (!(audio = macmf_audio_encoder_create(rate, 2, 0, rate, 192000, &audio_priming, asc, &asc_size))) return 8;
    audio_first_time = 0;
    for (i = 0; i < seconds * 100; ++i)
    {
        int16_t pcm[480 * 2];
        unsigned int j;

        for (j = 0; j < 480; ++j)
        {
            double t = (i * 480.0 + j) / rate;
            pcm[2 * j] = (int16_t)(12000 * sin(2 * M_PI * 440 * t));
            pcm[2 * j + 1] = (int16_t)(12000 * sin(2 * M_PI * 880 * t));
        }
        if (macmf_audio_encoder_encode(audio, (uint8_t *)pcm, sizeof(pcm)) != MACMF_OK) return 9;
        if (drain_audio(audio, rate)) return 10;
    }
    if (macmf_audio_encoder_drain(audio) != MACMF_OK || drain_audio(audio, rate)) return 11;

    qsort(packets, packet_count, sizeof(*packets), by_time);

    if (!(muxer = macmf_muxer_create())) return 12;
    if ((video_track = macmf_muxer_add_track(muxer, 0, width, height, 0, 0, 0, config, config_size)) < 0) return 13;
    if ((audio_track = macmf_muxer_add_track(muxer, 1, 0, 0, rate, 2, audio_priming, asc, asc_size)) < 0) return 14;
    for (i = 0; i < packet_count; ++i)
    {
        struct stored *p = &packets[i];
        if (macmf_muxer_write(muxer, p->track ? audio_track : video_track, p->data, p->info.size, p->info.time,
                p->track ? p->info.time : p->info.decode_time, p->info.duration, p->info.keyframe) != MACMF_OK)
            return 15;
    }
    if (macmf_muxer_finish(muxer, &total) != MACMF_OK) return 16;

    if (!(out = fopen(path, "wb"))) return 17;
    for (offset = 0; offset < total; offset += size)
    {
        if (macmf_muxer_read(muxer, offset, buffer, sizeof(buffer), &size) != MACMF_OK || !size) return 18;
        fwrite(buffer, 1, size, out);
    }
    fclose(out);
    macmf_muxer_destroy(muxer);
    macmf_video_encoder_destroy(video);
    macmf_audio_encoder_destroy(audio);
    printf("{\"bytes\": %llu, \"video_packets\": %zu, \"audio_packets\": %u, \"priming\": %u}\n",
            (unsigned long long)total, packet_count - audio_packets, audio_packets, audio_priming);
    return 0;
}
