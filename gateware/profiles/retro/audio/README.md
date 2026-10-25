# RETRO HDMI audio

Fixed 640×480/VIC1, 800×525 raster. No new PLL, generated audio clock or serializer.
`retro_hdmi_audio_tx` uses `vpx_t` coordinates, RGB and HS/VS from the same input cycle
and the existing `tmds_encoder` / `tmds_phy_se`. Its lane latency matches `hdmi_tx`.

```systemverilog
retro_audio_cdc #(.ClockHz(100000000)) u_audio (
    .clk_src(clk_100m), .rst_src(audio_reset_100m),
    .sample_valid(held_sample_valid), .sample_l(held_l), .sample_r(held_r),
    .clk_pix, .rst_pix(audio_reset_pix), .audio_valid, .audio_l, .audio_r);
retro_hdmi_audio_tx #(.InvMask(4'b0000), .PixelHz(25187500)) u_hdmi (
    .clk_pix, .clk_5x, .rst_pix(audio_reset_pix), .px,
    .audio_valid, .audio_l, .audio_r, .pad_p, .pad_n,
    .lane_debug(), .sample_ce(), .overflow());
```

`audio_valid` and `sample_valid` qualify **held samples**, not single-cycle strobes.
For NES unsigned raw16, use `$signed({~raw[15], raw[14:0]})` on both channels.
The checked `APUMixer` emits an unsigned LUT sum (`core/src/apu.v`); no high-pass/DC
removal is provided here. MD samples are signed16. Capture SNES signed16 on its
service-qualified sample-ready pulse and hold it with a valid level. Select game
sources in the integrator, not by clocking a fabric mux or using synthetic tones.

Reset both CDC domains on a system change. Keep source reset asserted at least four
pixel cycles while pixel reset drains old `cdc_word` events. All old audio packets
are discarded by `rst_pix`. Resume `sample_valid` only when the new source is ready.
Source clocks must match `ClockHz`; the 48 kHz CE spacing must be at least four
pixel cycles (`cdc_word` contract). Integration XDC must bound `u_sample/word_q`
to its destination bundle capture to one pixel period as described in `cdc_word`.
This is zero-order hold, **not** band-limited resampling.

The pixel NCO emits exactly `floor(cycles*48000/PixelHz)` samples. ACR N=6144; CTS
counts pixel cycles per 48 samples (25187 / 25188 at 25.1875 MHz). ACR precedes audio,
then pending Audio/AVI/SPD InfoFrames, at least once per field. Three 32-pixel packets
fit every line at x=654..749, with the standard preamble/guard windows. Four samples
assemble while four await transmission; overflow is sticky and should remain zero
for the documented raster. Silence is transmitted if audio is not yet valid.

`manifest.json` records sources, dependencies and MIT upstream reference hashes.
No upstream serializer or `clk_audio` capture logic is used. Optional debug outputs
can be unconnected in the full top. `tb_retro_audio*.sv` decode the actual lane words,
not internal packet headers. ODDR in the HDMI testbench is simulation-only.
