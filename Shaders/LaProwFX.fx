///////////////////////////////////////////////////////////////////////////////////
// LaProwFX.fx — Camera Raw All‑in‑One (Extended Edition)
///////////////////////////////////////////////////////////////////////////////////

// Requirements & includes
#include "ReShade.fxh"
#include "ReShadeUI.fxh"

// Compatibility checks
#if !defined(__RESHADE__) || __RESHADE__ < 50900
	#error "Outdated ReShade installation — ReShade 5.9+ required"
#endif
#if __RENDERER__ == 0x9000
	#error "This effect is not compatible with DirectX 9"
#endif

// =================================================================================
// Constants & helpers
// =================================================================================
static const float2 TEXEL_SIZE = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);
static const float  EPSILON    = 1e-6;

#define BUFFER_COLOR_SPACE_IS_HDR __RESHADE__ >= 50900 && BUFFER_COLOR_SPACE != 0

float luma709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

float3 saturate3(float3 v) { return float3(saturate(v.r), saturate(v.g), saturate(v.b)); }

float hash(float2 p)
{
	float3 p3 = frac(float3(p.xyx) * float3(443.897, 441.423, 437.195));
	p3 += dot(p3, p3.yzx + 19.19);
	return frac((p3.x + p3.y) * p3.z);
}

float distance_from_center(float2 uv)
{
	return length(uv - 0.5) * 2.0;
}

float3 rgb2hsv(float3 rgb)
{
	float4 K = float4(0.0, -1.0/3.0, 2.0/3.0, -1.0);
	float4 p = (rgb.g < rgb.b) ? float4(rgb.bg, K.wz) : float4(rgb.gb, K.xy);
	float4 q = (rgb.r < p.x) ? float4(p.xyw, rgb.r) : float4(rgb.r, p.yzx);
	float d = q.x - min(q.w, q.y);
	float e = 1.0e-10;
	return float3(abs(q.z + (q.w - q.y)/(6.0*d + e)), d/(q.x + e), q.x);
}

float3 hsv2rgb(float3 hsv)
{
	float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
	float3 p = abs(frac(hsv.xxx + K.xyz) * 6.0 - K.www);
	return hsv.z * lerp(K.xxx, saturate(p - K.xxx), hsv.y);
}

float3 s_curve(float3 c, float t)
{
	float a = saturate(0.5 + t * 0.5);
	float3 x = saturate3(c);
	return (x < a) ? 0.5 * pow(x / a, 1.0) : 1.0 - 0.5 * pow((1.0 - x) / (1.0 - a + EPSILON), 1.0);
}

// =================================================================================
// Textures & samplers
// =================================================================================
// Backbuffer is ReShade::BackBuffer

// 3D LUT strip texture (size N*N by N, e.g. 256x16 for N=16)
#ifndef LAPROW_LUT_PATH
	#define LAPROW_LUT_PATH "lut.png"
#endif
#ifndef LAPROW_LUT_SIZE
	#define LAPROW_LUT_SIZE 16 // Supports 16 or 32; 16 corresponds to 256x16 strip
#endif

texture LaProw_LUT < source = LAPROW_LUT_PATH; > { Width = LAPROW_LUT_SIZE*LAPROW_LUT_SIZE; Height = LAPROW_LUT_SIZE; Format = RGBA8; };
sampler sLaProw_LUT { Texture = LaProw_LUT; AddressU = CLAMP; AddressV = CLAMP; };

// Bloom textures and samplers
texture LaProw_BloomTex { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sLaProw_BloomTex { Texture = LaProw_BloomTex; AddressU = CLAMP; AddressV = CLAMP; };

texture LaProw_BloomTex2 { Width = BUFFER_WIDTH / 4; Height = BUFFER_HEIGHT / 4; Format = RGBA16F; };
sampler sLaProw_BloomTex2 { Texture = LaProw_BloomTex2; AddressU = CLAMP; AddressV = CLAMP; };

// DoF textures and samplers
texture LaProw_DoFTex { Width = BUFFER_WIDTH / 2; Height = BUFFER_HEIGHT / 2; Format = RGBA16F; };
sampler sLaProw_DoFTex { Texture = LaProw_DoFTex; AddressU = CLAMP; AddressV = CLAMP; };

// Lens Dirt texture
texture LaProw_LensDirtTex < source = "lens_dirt.png"; > { Width = 1024; Height = 1024; Format = RGBA8; };
sampler sLaProw_LensDirtTex { Texture = LaProw_LensDirtTex; AddressU = CLAMP; AddressV = CLAMP; };

// Lens Flare texture
texture LaProw_LensFlareTex < source = "lens_flare.png"; > { Width = 1024; Height = 1024; Format = RGBA8; };
sampler sLaProw_LensFlareTex { Texture = LaProw_LensFlareTex; AddressU = CLAMP; AddressV = CLAMP; };

// Frame counter for film grain randomization
uniform uint FrameCount < source = "framecount"; >;

// Pixel size for various effects
static const float2 TEXEL_SIZE = float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT);

// =================================================================================
// UI — About
// =================================================================================
uniform int UIHELP <
	ui_type = "radio";
	ui_label = " ";
	ui_text =
		"LaProwFX\n"
		"Version 4932891324.0\n\n"
		"LUT (strip N*N x N), blend\n"
		"Exposure/Contrast/Color\n"
		"WB (Temp/Tint) with Advanced Mode\n"
		"Highlights/Shadows/Midtone Color Grading\n"
		"Clarity (unsharp) & Tone curve\n"
		"Bloom, Film Grain, Vignette Styles\n"
		"Chromatic Aberration & HDR Support\n\n"
	ui_category = "About";
> = 0;

// =================================================================================
// UI — Basic Adjustments
// =================================================================================
uniform float Exposure < __UNIFORM_SLIDER_FLOAT1
	ui_min = -5.0; ui_max = 5.0; ui_step = 0.01;
	ui_label = "Exposure";
	ui_category = "Basic";
> = 0.0;

uniform float Contrast < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Contrast";
	ui_category = "Basic";
> = 0.0;

uniform float Saturation < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Saturation";
	ui_category = "Basic";
> = 0.0;

uniform float Vibrance < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Vibrance";
	ui_category = "Basic";
> = 0.0;

// =================================================================================
// UI — White Balance & Color
// =================================================================================
uniform float Temperature < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.001;
	ui_label = "Temperature";
	ui_tooltip = "- cold / + warm";
	ui_category = "Color";
> = 0.0;

uniform float Tint < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.001;
	ui_label = "Tint";
	ui_tooltip = "- green / + magenta";
	ui_category = "Color";
> = 0.0;

uniform bool AdvancedTint < __UNIFORM_INPUT_BOOL1
	ui_label = "Advanced White Balance";
	ui_tooltip = "Enable Bradford Chromatic Adaptation";
	ui_category = "Color";
> = false;

uniform float3 CustomTintColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Custom Tint Color";
	ui_category = "Color";
> = float3(1.0, 1.0, 1.0);

uniform float CustomTintStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Custom Tint Strength";
	ui_category = "Color";
> = 0.0;

uniform float HueShift < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 0.1;
	ui_label = "Hue Shift (°)";
	ui_category = "Color";
> = 0.0;

// =================================================================================
// UI — Tone
// =================================================================================
uniform float Highlights < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Highlights";
	ui_category = "Tone";
> = 0.0;

uniform float Shadows < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Shadows";
	ui_category = "Tone";
> = 0.0;

uniform float Clarity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
	ui_label = "Clarity";
	ui_category = "Tone";
> = 0.0;

uniform float ToneCurve < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.001;
	ui_label = "Tone Curve";
	ui_category = "Tone";
> = 0.0;

// =================================================================================
// UI — Grading (Highlight/Shadow/Midtone Color)
// =================================================================================
uniform bool EnableGrading < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Color Grading";
	ui_category = "Grading";
> = false;

// Basic Grading Controls
uniform int GradingMode < __UNIFORM_COMBO_INT1
	ui_items = "Basic\0Split Toning\0Color Wheels\0";
	ui_label = "Grading Mode";
	ui_tooltip = "Basic: Simple color tints for highlights/mids/shadows\nSplit Toning: Separate colors for highlights/shadows\nColor Wheels: DaVinci Resolve style color wheels";
	ui_category = "Grading";
> = 0;

// Basic Mode Controls
uniform float3 HighlightColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Highlight Color";
	ui_category = "Grading";
	ui_category_closed = true;
> = float3(1.0, 0.9, 0.8); // Slightly warm highlights

uniform float HighlightIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Highlight Intensity";
	ui_category = "Grading";
	ui_category_closed = true;
> = 0.0;

uniform float3 MidtoneColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Midtone Color";
	ui_category = "Grading";
	ui_category_closed = true;
> = float3(1.0, 1.0, 1.0); // Neutral midtones

uniform float MidtoneIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Midtone Intensity";
	ui_category = "Grading";
	ui_category_closed = true;
> = 0.0;

uniform float3 ShadowColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Shadow Color";
	ui_category = "Grading";
	ui_category_closed = true;
> = float3(0.2, 0.3, 0.5); // Slightly cool shadows

uniform float ShadowIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Shadow Intensity";
	ui_category = "Grading";
	ui_category_closed = true;
> = 0.0;

// Split Toning Controls
uniform float3 SplitHighlightColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Split Highlight Color";
	ui_category = "Split Toning";
> = float3(1.0, 0.9, 0.7); // Warm highlights

uniform float SplitHighlightIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Split Highlight Intensity";
	ui_category = "Split Toning";
> = 0.0;

uniform float3 SplitShadowColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Split Shadow Color";
	ui_category = "Split Toning";
> = float3(0.2, 0.4, 0.6); // Cool shadows

uniform float SplitShadowIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Split Shadow Intensity";
	ui_category = "Split Toning";
> = 0.0;

uniform float SplitBalance < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Split Balance";
	ui_tooltip = "Adjusts the balance between highlights and shadows";
	ui_category = "Split Toning";
> = 0.0;

// Color Wheels Controls
uniform float3 WheelShadowsColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Shadows Color Wheel";
	ui_category = "Color Wheels";
> = float3(1.0, 1.0, 1.0); // Neutral

uniform float WheelShadowsStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Shadows Strength";
	ui_category = "Color Wheels";
> = 0.0;

uniform float WheelShadowsLuma < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Shadows Luma";
	ui_tooltip = "Adjusts the luminance of shadow regions";
	ui_category = "Color Wheels";
> = 0.0;

uniform float3 WheelMidtonesColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Midtones Color Wheel";
	ui_category = "Color Wheels";
> = float3(1.0, 1.0, 1.0); // Neutral

uniform float WheelMidtonesStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Midtones Strength";
	ui_category = "Color Wheels";
> = 0.0;

uniform float WheelMidtonesLuma < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Midtones Luma";
	ui_tooltip = "Adjusts the luminance of midtone regions";
	ui_category = "Color Wheels";
> = 0.0;

uniform float3 WheelHighlightsColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Highlights Color Wheel";
	ui_category = "Color Wheels";
> = float3(1.0, 1.0, 1.0); // Neutral

uniform float WheelHighlightsStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Highlights Strength";
	ui_category = "Color Wheels";
> = 0.0;

uniform float WheelHighlightsLuma < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Highlights Luma";
	ui_tooltip = "Adjusts the luminance of highlight regions";
	ui_category = "Color Wheels";
> = 0.0;

// =================================================================================
// UI — HSL Adjustments
// =================================================================================
uniform bool EnableHSL < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable HSL Adjustments";
	ui_category = "HSL";
> = false;

// Red channel adjustments
uniform float HueRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Red Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Red Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Red Luminance";
	ui_category = "HSL";
> = 0.0;

// Orange channel adjustments
uniform float HueOrange < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Orange Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationOrange < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Orange Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceOrange < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Orange Luminance";
	ui_category = "HSL";
> = 0.0;

// Yellow channel adjustments
uniform float HueYellow < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Yellow Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationYellow < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Yellow Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceYellow < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Yellow Luminance";
	ui_category = "HSL";
> = 0.0;

// Green channel adjustments
uniform float HueGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Green Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Green Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Green Luminance";
	ui_category = "HSL";
> = 0.0;

// Aqua channel adjustments
uniform float HueAqua < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Aqua Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationAqua < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Aqua Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceAqua < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Aqua Luminance";
	ui_category = "HSL";
> = 0.0;

// Blue channel adjustments
uniform float HueBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Blue Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Blue Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Blue Luminance";
	ui_category = "HSL";
> = 0.0;

// Purple channel adjustments
uniform float HuePurple < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Purple Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationPurple < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Purple Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminancePurple < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Purple Luminance";
	ui_category = "HSL";
> = 0.0;

// Magenta channel adjustments
uniform float HueMagenta < __UNIFORM_SLIDER_FLOAT1
	ui_min = -180.0; ui_max = 180.0; ui_step = 1.0;
	ui_label = "Magenta Hue";
	ui_category = "HSL";
> = 0.0;

uniform float SaturationMagenta < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Magenta Saturation";
	ui_category = "HSL";
> = 0.0;

uniform float LuminanceMagenta < __UNIFORM_SLIDER_FLOAT1
	ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Magenta Luminance";
	ui_category = "HSL";
> = 0.0;

// =================================================================================
// UI — Bloom
// =================================================================================
uniform bool EnableBloom < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Bloom";
	ui_category = "Bloom";
> = false;

uniform float BloomStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Bloom Strength";
	ui_category = "Bloom";
> = 0.2;

uniform float BloomRadius < __UNIFORM_SLIDER_FLOAT1
	ui_min = 1.0; ui_max = 5.0; ui_step = 0.1;
	ui_label = "Bloom Radius";
	ui_category = "Bloom";
> = 2.0;

uniform float BloomThreshold < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Bloom Threshold";
	ui_category = "Bloom";
> = 0.7;

// =================================================================================
// UI — Film Grain & Vignette
// =================================================================================
uniform bool EnableFilmGrain < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Film Grain";
	ui_category = "Film Grain & Vignette";
> = false;

uniform float GrainIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Grain Intensity";
	ui_category = "Film Grain & Vignette";
> = 0.1;

uniform float GrainSize < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.5; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Grain Size";
	ui_category = "Film Grain & Vignette";
> = 1.0;

uniform bool EnableVignette < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Vignette";
	ui_category = "Film Grain & Vignette";
> = false;

uniform int VignetteStyle < __UNIFORM_COMBO_INT1
	ui_items = "Circle\0Box\0Bottom Fade\0Top Fade\0Sky-focused\0";
	ui_label = "Vignette Style";
	ui_category = "Film Grain & Vignette";
> = 0;

uniform float VignetteStrength < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Vignette Strength";
	ui_category = "Film Grain & Vignette";
> = 0.3;

uniform float VignetteRadius < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
	ui_label = "Vignette Radius";
	ui_category = "Film Grain & Vignette";
> = 1.0;

uniform float VignetteFeather < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Vignette Feather";
	ui_category = "Film Grain & Vignette";
> = 0.2;

uniform float3 VignetteColor < __UNIFORM_COLOR_FLOAT3
	ui_label = "Vignette Color";
	ui_category = "Film Grain & Vignette";
> = float3(0.0, 0.0, 0.0);

// =================================================================================
// UI — Chromatic Aberration
// =================================================================================
uniform bool EnableCA < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Chromatic Aberration";
	ui_category = "Chromatic Aberration";
> = false;

uniform float CARadius < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Clean Center Radius";
	ui_category = "Chromatic Aberration";
> = 0.5;

uniform float CAIntensity < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 5.0; ui_step = 0.01;
	ui_label = "CA Intensity";
	ui_category = "Chromatic Aberration";
> = 1.0;

// =================================================================================
// UI — Channel Mixer
// =================================================================================
uniform bool EnableChannelMixer < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable Channel Mixer";
	ui_category = "Channel Mixer";
> = false;

// Red channel output controls
uniform float RedToRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Red to Red";
	ui_tooltip = "Amount of Red channel in the Red output";
	ui_category = "Channel Mixer";
> = 1.0;

uniform float GreenToRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Green to Red";
	ui_tooltip = "Amount of Green channel in the Red output";
	ui_category = "Channel Mixer";
> = 0.0;

uniform float BlueToRed < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Blue to Red";
	ui_tooltip = "Amount of Blue channel in the Red output";
	ui_category = "Channel Mixer";
> = 0.0;

// Green channel output controls
uniform float RedToGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Red to Green";
	ui_tooltip = "Amount of Red channel in the Green output";
	ui_category = "Channel Mixer";
> = 0.0;

uniform float GreenToGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Green to Green";
	ui_tooltip = "Amount of Green channel in the Green output";
	ui_category = "Channel Mixer";
> = 1.0;

uniform float BlueToGreen < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Blue to Green";
	ui_tooltip = "Amount of Blue channel in the Green output";
	ui_category = "Channel Mixer";
> = 0.0;

// Blue channel output controls
uniform float RedToBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Red to Blue";
	ui_tooltip = "Amount of Red channel in the Blue output";
	ui_category = "Channel Mixer";
> = 0.0;

uniform float GreenToBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Green to Blue";
	ui_tooltip = "Amount of Green channel in the Blue output";
	ui_category = "Channel Mixer";
> = 0.0;

uniform float BlueToBlue < __UNIFORM_SLIDER_FLOAT1
	ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
	ui_label = "Blue to Blue";
	ui_tooltip = "Amount of Blue channel in the Blue output";
	ui_category = "Channel Mixer";
> = 1.0;

// Monochrome mixer
uniform bool MonochromeMode < __UNIFORM_INPUT_BOOL1
	ui_label = "Monochrome Mode";
	ui_tooltip = "Convert to black and white using channel mixer";
	ui_category = "Channel Mixer";
> = false;

uniform float RedToMono < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Red to Mono";
	ui_tooltip = "Amount of Red channel in the monochrome output";
	ui_category = "Channel Mixer";
> = 0.30;

uniform float GreenToMono < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Green to Mono";
	ui_tooltip = "Amount of Green channel in the monochrome output";
	ui_category = "Channel Mixer";
> = 0.59;

uniform float BlueToMono < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
	ui_label = "Blue to Mono";
	ui_tooltip = "Amount of Blue channel in the monochrome output";
	ui_category = "Channel Mixer";
> = 0.11;

// =================================================================================
// UI — LUT
// =================================================================================
uniform bool EnableLUT < __UNIFORM_INPUT_BOOL1
	ui_label = "Enable LUT";
	ui_category = "LUT";
> = false;

uniform float LUTBlend < __UNIFORM_SLIDER_FLOAT1
	ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
	ui_label = "LUT Blend";
	ui_category = "LUT";
> = 1.0;

uniform int LUTSize < __UNIFORM_SLIDER_INT1
	ui_min = 16; ui_max = 32; ui_step = 16;
	ui_label = "LUT Size (N)";
	ui_tooltip = "Strip dimensions N*N x N";
	ui_category = "LUT";
> = LAPROW_LUT_SIZE;

// =================================================================================
// Color math blocks
// =================================================================================
float3 apply_exposure(float3 color, float exposure)
{
	return color * pow(2.0, exposure);
}

float3 apply_contrast(float3 color, float contrast)
{
	// Contrast around mid grey 0.5 in linear space
	const float3 mid = 0.5.xxx;
	return lerp(mid, color, 1.0 + contrast);
}

float3 apply_saturation(float3 color, float sat)
{
	float l = luma709(color);
	return lerp(float3(l, l, l), color, 1.0 + sat);
}

float3 apply_vibrance(float3 color, float v)
{
	float mx = max(color.r, max(color.g, color.b));
	float mn = min(color.r, min(color.g, color.b));
	float s  = mx - mn; // crude saturation
	float amt = (v >= 0.0) ? (1.0 - s) * v : -s * v; // protect already saturated colors
	float l = luma709(color);
	return lerp(float3(l, l, l), color, 1.0 + amt);
}

// Bradford Chromatic Adaptation matrices
static const float3x3 BRADFORD_MATRIX = float3x3(
	0.8951, 0.2664, -0.1614,
	-0.7502, 1.7135, 0.0367,
	0.0389, -0.0685, 1.0296
);

static const float3x3 BRADFORD_MATRIX_INV = float3x3(
	0.9869929, -0.1470543, 0.1599627,
	0.4323053, 0.5183603, 0.0492912,
	-0.0085287, 0.0400428, 0.9684867
);

// Apply Bradford Chromatic Adaptation
float3 apply_bradford_adaptation(float3 xyz, float3 source_white, float3 dest_white)
{
	// Convert to cone response domain
	float3 source_lms = mul(BRADFORD_MATRIX, xyz);
	float3 source_white_lms = mul(BRADFORD_MATRIX, source_white);
	float3 dest_white_lms = mul(BRADFORD_MATRIX, dest_white);
	
	// Calculate the cone response ratios
	float3 lms_ratio = dest_white_lms / source_white_lms;
	
	// Apply the adaptation
	float3 adapted_lms = source_lms * lms_ratio;
	
	// Convert back to XYZ
	return mul(BRADFORD_MATRIX_INV, adapted_lms);
}

// Convert RGB to XYZ using sRGB primaries and D65 white point
float3 rgb_to_xyz(float3 rgb)
{
	// sRGB to XYZ matrix (D65 white point)
	const float3x3 RGB_TO_XYZ = float3x3(
		0.4124564, 0.3575761, 0.1804375,
		0.2126729, 0.7151522, 0.0721750,
		0.0193339, 0.1191920, 0.9503041
	);
	
	return mul(RGB_TO_XYZ, rgb);
}

// Convert XYZ to RGB using sRGB primaries and D65 white point
float3 xyz_to_rgb(float3 xyz)
{
	// XYZ to sRGB matrix (D65 white point)
	const float3x3 XYZ_TO_RGB = float3x3(
		3.2404542, -1.5371385, -0.4985314,
		-0.9692660, 1.8760108, 0.0415560,
		0.0556434, -0.2040259, 1.0572252
	);
	
	return mul(XYZ_TO_RGB, xyz);
}

// Calculate white point for a given color temperature
float3 calculate_white_point(float temperature)
{
	// Approximate white point based on temperature
	// This is a simplified approximation of the Planckian locus
	float temp_k = 6500.0 + temperature * 4000.0; // Map [-1,1] to [2500,10500]K
	temp_k = clamp(temp_k, 1000.0, 40000.0);
	
	// Calculate chromaticity coordinates
	float x, y;
	
	if (temp_k <= 7000.0)
	{
		x = 0.244063 + 0.09911e3 / temp_k + 2.9678e6 / (temp_k * temp_k) - 4.6070e9 / (temp_k * temp_k * temp_k);
	}
	else
	{
		x = 0.237040 + 0.24748e3 / temp_k + 1.9018e6 / (temp_k * temp_k) - 2.0064e9 / (temp_k * temp_k * temp_k);
	}
	
	// Calculate y from x
	y = -0.275 + 2.870 * x - 3.000 * x * x;
	
	// Calculate XYZ from xy
	float X = x / y;
	float Y = 1.0;
	float Z = (1.0 - x - y) / y;
	
	return float3(X, Y, Z);
}

float3 apply_temperature_tint(float3 c, float temp, float tint, bool advanced_mode, float3 custom_tint_color, float custom_tint_strength)
{
	if (!advanced_mode)
	{
		// Simple slope/offset model in linear RGB; temp warms/cools R/B, tint pushes G
		float rmul = 1.0 + temp * 0.20; // +/-20%
		float bmul = 1.0 - temp * 0.20;
		float gmul = 1.0 + tint * 0.20 * (tint > 0 ? 1.0 : -1.0);
		c.r *= rmul; c.g *= gmul; c.b *= bmul;
	}
	else
	{
		// Advanced mode: Bradford Chromatic Adaptation + Custom Tint Color
		// D65 white point (standard sRGB white point)
		const float3 D65_WHITE = float3(0.95047, 1.0, 1.08883);
		
		// Calculate target white point based on temperature
		float3 target_white = calculate_white_point(temp);
		
		// Apply tint adjustment to target white point
		target_white.y *= (1.0 - tint * 0.05); // Adjust Y component for green-magenta shift
		
		// Convert RGB to XYZ
		float3 xyz = rgb_to_xyz(c);
		
		// Apply Bradford chromatic adaptation
		float3 adapted_xyz = apply_bradford_adaptation(xyz, D65_WHITE, target_white);
		
		// Convert back to RGB
		c = xyz_to_rgb(adapted_xyz);
		
		// Apply custom tint color with strength
		c = lerp(c, c * custom_tint_color, custom_tint_strength);
	}
	return saturate3(c);
}

float3 apply_hue_shift(float3 c, float degrees)
{
	float3 hsv = rgb2hsv(saturate3(c));
	hsv.x = frac(hsv.x + degrees / 360.0);
	return hsv2rgb(hsv);
}

// Calculate the weight for a specific color range based on hue
float calculate_hue_weight(float hue, float target_hue, float width)
{
	// Normalize hues to [0, 1] range
	hue = frac(hue);
	target_hue = frac(target_hue);
	
	// Calculate distance in both directions (accounting for wrap-around)
	float dist1 = abs(hue - target_hue);
	float dist2 = 1.0 - dist1;
	float dist = min(dist1, dist2);
	
	// Return weight based on distance (smoothstep for soft falloff)
	return smoothstep(width, 0.0, dist);
}

// Apply HSL adjustments to specific color ranges
float3 apply_hsl_adjustments(float3 c)
{
	// Convert to HSV for processing
	float3 hsv = rgb2hsv(saturate3(c));
	
	// Define target hues for each color range (in normalized [0,1] range)
	float red_hue = 0.0 / 360.0;
	float orange_hue = 30.0 / 360.0;
	float yellow_hue = 60.0 / 360.0;
	float green_hue = 120.0 / 360.0;
	float aqua_hue = 180.0 / 360.0;
	float blue_hue = 240.0 / 360.0;
	float purple_hue = 270.0 / 360.0;
	float magenta_hue = 300.0 / 360.0;
	
	// Width of each color range (adjust for overlap as needed)
	float width = 0.08; // About 30 degrees
	
	// Calculate weights for each color range
	float w_red = calculate_hue_weight(hsv.x, red_hue, width);
	float w_orange = calculate_hue_weight(hsv.x, orange_hue, width);
	float w_yellow = calculate_hue_weight(hsv.x, yellow_hue, width);
	float w_green = calculate_hue_weight(hsv.x, green_hue, width);
	float w_aqua = calculate_hue_weight(hsv.x, aqua_hue, width);
	float w_blue = calculate_hue_weight(hsv.x, blue_hue, width);
	float w_purple = calculate_hue_weight(hsv.x, purple_hue, width);
	float w_magenta = calculate_hue_weight(hsv.x, magenta_hue, width);
	
	// Normalize weights to ensure they sum to 1.0
	float w_sum = w_red + w_orange + w_yellow + w_green + w_aqua + w_blue + w_purple + w_magenta;
	if (w_sum > 0.0)
	{
		w_red /= w_sum;
		w_orange /= w_sum;
		w_yellow /= w_sum;
		w_green /= w_sum;
		w_aqua /= w_sum;
		w_blue /= w_sum;
		w_purple /= w_sum;
		w_magenta /= w_sum;
	}
	
	// Apply hue adjustments
	float hue_shift = 0.0;
	hue_shift += w_red * (HueRed / 360.0);
	hue_shift += w_orange * (HueOrange / 360.0);
	hue_shift += w_yellow * (HueYellow / 360.0);
	hue_shift += w_green * (HueGreen / 360.0);
	hue_shift += w_aqua * (HueAqua / 360.0);
	hue_shift += w_blue * (HueBlue / 360.0);
	hue_shift += w_purple * (HuePurple / 360.0);
	hue_shift += w_magenta * (HueMagenta / 360.0);
	hsv.x = frac(hsv.x + hue_shift);
	
	// Apply saturation adjustments
	float sat_adjust = 0.0;
	sat_adjust += w_red * SaturationRed;
	sat_adjust += w_orange * SaturationOrange;
	sat_adjust += w_yellow * SaturationYellow;
	sat_adjust += w_green * SaturationGreen;
	sat_adjust += w_aqua * SaturationAqua;
	sat_adjust += w_blue * SaturationBlue;
	sat_adjust += w_purple * SaturationPurple;
	sat_adjust += w_magenta * SaturationMagenta;
	hsv.y = saturate(hsv.y * (1.0 + sat_adjust));
	
	// Apply luminance adjustments
	float lum_adjust = 0.0;
	lum_adjust += w_red * LuminanceRed;
	lum_adjust += w_orange * LuminanceOrange;
	lum_adjust += w_yellow * LuminanceYellow;
	lum_adjust += w_green * LuminanceGreen;
	lum_adjust += w_aqua * LuminanceAqua;
	lum_adjust += w_blue * LuminanceBlue;
	lum_adjust += w_purple * LuminancePurple;
	lum_adjust += w_magenta * LuminanceMagenta;
	hsv.z = saturate(hsv.z * (1.0 + lum_adjust * 0.5));
	
	// Convert back to RGB
	return hsv2rgb(hsv);
}

// Apply Channel Mixer adjustments
float3 apply_channel_mixer(float3 c)
{
	// Extract original RGB channels
	float r = c.r;
	float g = c.g;
	float b = c.b;
	
	// Apply channel mixing
	float new_r = r * RedToRed + g * GreenToRed + b * BlueToRed;
	float new_g = r * RedToGreen + g * GreenToGreen + b * BlueToGreen;
	float new_b = r * RedToBlue + g * GreenToBlue + b * BlueToBlue;
	
	// Create new color
	float3 result = float3(new_r, new_g, new_b);
	
	// Apply monochrome mode if enabled
	if (MonochromeMode)
	{
		// Calculate monochrome value using custom weights
		float mono = r * RedToMono + g * GreenToMono + b * BlueToMono;
		
		// Create monochrome result
		result = float3(mono, mono, mono);
	}
	
	return saturate3(result);
}

float3 apply_highlights_shadows(float3 c, float hi, float sh)
{
	float l = luma709(c);
	float hiMask = smoothstep(0.55, 1.00, l);
	float shMask = 1.0 - smoothstep(0.00, 0.45, l);
	float3 hiAdj = c * (1.0 + hi * hiMask);
	float3 shAdj = c * (1.0 + sh * shMask);
	// Blend with masks weighted by luminance location
	return lerp(shAdj, hiAdj, hiMask);
}

// Apply basic color grading to highlights, midtones, and shadows
float3 apply_basic_color_grading(float3 c, float3 highlight_color, float highlight_intensity, 
                          float3 midtone_color, float midtone_intensity, 
                          float3 shadow_color, float shadow_intensity)
{
	float l = luma709(c);
	
	// Create masks for highlights, midtones, and shadows
	float hiMask = smoothstep(0.55, 1.00, l);
	float shMask = 1.0 - smoothstep(0.00, 0.45, l);
	float midMask = 1.0 - hiMask - shMask;
	
	// Apply color grading to each zone
	float3 hiColor = lerp(c, c * highlight_color, highlight_intensity * hiMask);
	float3 midColor = lerp(c, c * midtone_color, midtone_intensity * midMask);
	float3 shColor = lerp(c, c * shadow_color, shadow_intensity * shMask);
	
	// Blend the results based on the masks
	float3 result = c;
	result = lerp(result, hiColor, hiMask);
	result = lerp(result, midColor, midMask);
	result = lerp(result, shColor, shMask);
	
	return result;
}

// Apply split toning (separate colors for highlights and shadows)
float3 apply_split_toning(float3 c, float3 highlight_color, float highlight_intensity,
                         float3 shadow_color, float shadow_intensity, float balance)
{
	float l = luma709(c);
	
	// Adjust the balance between highlights and shadows
	// Balance: -1.0 (more shadows) to 1.0 (more highlights)
	float hiThreshold = 0.5 + (balance * 0.25); // 0.25 to 0.75
	float shThreshold = 0.5 - (balance * 0.25); // 0.75 to 0.25
	
	// Create masks with adjusted thresholds
	float hiMask = smoothstep(hiThreshold, 1.0, l);
	float shMask = 1.0 - smoothstep(0.0, shThreshold, l);
	
	// Apply color grading to highlights and shadows
	float3 hiColor = lerp(c, c * highlight_color, highlight_intensity * hiMask);
	float3 shColor = lerp(c, c * shadow_color, shadow_intensity * shMask);
	
	// Blend the results
	float3 result = c;
	result = lerp(result, hiColor, hiMask);
	result = lerp(result, shColor, shMask);
	
	return result;
}

// Apply color wheels grading (DaVinci Resolve style)
float3 apply_color_wheels(float3 c, 
                         float3 shadows_color, float shadows_strength, float shadows_luma,
                         float3 midtones_color, float midtones_strength, float midtones_luma,
                         float3 highlights_color, float highlights_strength, float highlights_luma)
{
	float l = luma709(c);
	
	// Create masks for highlights, midtones, and shadows with smoother transitions
	float hiMask = smoothstep(0.55, 0.95, l);
	float shMask = 1.0 - smoothstep(0.05, 0.45, l);
	float midMask = 1.0 - hiMask - shMask;
	
	// Apply color grading with both color and luma adjustments
	// Shadows
	float3 shColor = c * shadows_color;
	float shLuma = luma709(shColor);
	float shLumaAdj = shLuma * (1.0 + shadows_luma * 0.5);
	float3 shColorAdj = shColor * (shLumaAdj / max(shLuma, EPSILON));
	float3 shResult = lerp(c, shColorAdj, shadows_strength * shMask);
	
	// Midtones
	float3 midColor = c * midtones_color;
	float midLuma = luma709(midColor);
	float midLumaAdj = midLuma * (1.0 + midtones_luma * 0.5);
	float3 midColorAdj = midColor * (midLumaAdj / max(midLuma, EPSILON));
	float3 midResult = lerp(c, midColorAdj, midtones_strength * midMask);
	
	// Highlights
	float3 hiColor = c * highlights_color;
	float hiLuma = luma709(hiColor);
	float hiLumaAdj = hiLuma * (1.0 + highlights_luma * 0.5);
	float3 hiColorAdj = hiColor * (hiLumaAdj / max(hiLuma, EPSILON));
	float3 hiResult = lerp(c, hiColorAdj, highlights_strength * hiMask);
	
	// Blend the results
	float3 result = c;
	result = lerp(result, shResult, shMask);
	result = lerp(result, midResult, midMask);
	result = lerp(result, hiResult, hiMask);
	
	return result;
}

// Main color grading function that selects the appropriate grading method
float3 apply_color_grading(float3 c, int mode)
{
	switch(mode)
	{
		case 0: // Basic
			return apply_basic_color_grading(c, HighlightColor, HighlightIntensity,
			                            MidtoneColor, MidtoneIntensity,
			                            ShadowColor, ShadowIntensity);
			
		case 1: // Split Toning
			return apply_split_toning(c, SplitHighlightColor, SplitHighlightIntensity,
			                      SplitShadowColor, SplitShadowIntensity,
			                      SplitBalance);
			
		case 2: // Color Wheels
			return apply_color_wheels(c,
			                      WheelShadowsColor, WheelShadowsStrength, WheelShadowsLuma,
			                      WheelMidtonesColor, WheelMidtonesStrength, WheelMidtonesLuma,
			                      WheelHighlightsColor, WheelHighlightsStrength, WheelHighlightsLuma);
			
		default:
			return c;
	}
}

float3 apply_tone_curve(float3 c, float t)
{
	return s_curve(c, t);
}

// Lightweight clarity: unsharp mask using 4-neighbour blur
float3 apply_clarity(float2 uv, float3 c, float strength)
{
	if (strength <= 0.0) return c;
	float2 px = TEXEL_SIZE * 1.0;
	float3 b = (
		tex2D(ReShade::BackBuffer, uv + float2( px.x, 0)).rgb +
		tex2D(ReShade::BackBuffer, uv + float2(-px.x, 0)).rgb +
		tex2D(ReShade::BackBuffer, uv + float2(0,  px.y)).rgb +
		tex2D(ReShade::BackBuffer, uv + float2(0, -px.y)).rgb
	) * 0.25;
	float3 hi = c - b; // high frequency
	return saturate3(c + hi * strength * 0.75);
}

// Bloom functions
float3 threshold_color(float3 color, float threshold)
{
	float brightness = luma709(color);
	return color * max(0.0, brightness - threshold) / max(brightness, EPSILON);
}

float3 apply_bloom(float2 uv, float3 color, float strength, float radius, float threshold)
{
	// Skip if bloom is disabled or strength is zero
	if (strength <= 0.0) return color;
	
	// Extract bright parts
	float3 bloom = threshold_color(color, threshold);
	
	// Downsample and blur (first pass)
	float2 pixelSize = TEXEL_SIZE * radius;
	float2 coord = uv;
	float3 blur1 = 0.0;
	
	for (int x = -2; x <= 2; x++)
	{
		for (int y = -2; y <= 2; y++)
		{
			float2 offset = float2(x, y) * pixelSize;
			blur1 += threshold_color(tex2D(ReShade::BackBuffer, coord + offset).rgb, threshold);
		}
	}
	blur1 /= 25.0;
	
	// Apply bloom additively
	return saturate3(color + blur1 * strength);
}

// Film grain function
float3 apply_film_grain(float2 uv, float3 color, float intensity, float grain_size, uint frame)
{
	if (intensity <= 0.0) return color;
	
	// Scale UVs for grain size
	float2 grain_uv = uv * float2(BUFFER_WIDTH, BUFFER_HEIGHT) / grain_size;
	
	
	// Generate noise
	float noise = hash(grain_uv);
	
	// Apply grain
	float3 grain = noise - 0.5;
	return saturate3(color + grain * intensity * 0.1);
}

// Vignette function
float3 apply_vignette(float2 uv, float3 color, int style, float strength, float radius, float feather, float3 vignette_color)
{
	if (strength <= 0.0) return color;
	
	float vignette = 0.0;
	
	switch(style)
	{
		case 0: // Circle
			vignette = distance_from_center(uv) / radius;
			break;
		case 1: // Box
			{
				float2 centered = abs(uv - 0.5) * 2.0;
				vignette = max(centered.x, centered.y) / radius;
			}
			break;
		case 2: // Bottom Fade
			vignette = (1.0 - uv.y) / radius;
			break;
		case 3: // Top Fade
			vignette = uv.y / radius;
			break;
		case 4: // Sky-focused (stronger in upper half)
			{
				float base = distance_from_center(uv) / radius;
				float sky_weight = smoothstep(0.0, 1.0, uv.y);
				vignette = base * (1.0 + sky_weight * 0.5);
			}
			break;
	}
	
	// Apply feathering
	vignette = smoothstep(0.0, 1.0 + feather, vignette);
	
	// Mix with color
	return lerp(color, color * (1.0 - vignette_color), vignette * strength);
}

// Chromatic aberration function
float3 apply_chromatic_aberration(float2 uv, float3 color, float clean_radius, float intensity)
{
	if (intensity <= 0.0) return color;
	
	// Calculate distance from center
	float dist = distance_from_center(uv);
	
	// Skip if inside clean radius
	if (dist < clean_radius) return color;
	
	// Calculate effect strength based on distance from clean radius
	float effect_strength = smoothstep(clean_radius, 1.0, dist) * intensity;
	
	// Calculate offset direction
	float2 dir = normalize(uv - 0.5);
	
	// Sample with offsets
	float2 offset = dir * TEXEL_SIZE * effect_strength;
	float3 r = tex2D(ReShade::BackBuffer, uv + offset).rgb;
	float3 g = color;
	float3 b = tex2D(ReShade::BackBuffer, uv - offset).rgb;
	
	// Combine channels
	return float3(r.r, g.g, b.b);
}

// 3D LUT sampling for strip (N*N by N). Works for N=16 or 32.
float3 sample_lut_strip(float3 color, int N)
{
	color = saturate3(color);
	float slice = color.b * (N - 1);
	float sliceF = floor(slice);
	float sliceC = min(sliceF + 1.0, N - 1);
	float f = frac(slice);

	float uA = (sliceF * N + color.r * (N - 1)) + 0.5;
	float uB = (sliceC * N + color.r * (N - 1)) + 0.5;
	float v  = (color.g * (N - 1)) + 0.5;

	float2 uvA = float2(uA / (N * N), v / N);
	float2 uvB = float2(uB / (N * N), v / N);
	float3 CA = tex2D(sLaProw_LUT, uvA).rgb;
	float3 CB = tex2D(sLaProw_LUT, uvB).rgb;
	return lerp(CA, CB, f);
}

// =================================================================================
// Pixel shader pipeline
// =================================================================================
float3 LaProw_Pipeline(float2 uv)
{
	float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
	
	// HDR detection and processing
	bool is_hdr = BUFFER_COLOR_SPACE_IS_HDR;


	// Basic
	c = apply_exposure(c, Exposure);
	c = apply_contrast(c, Contrast);

	// WB/Color
	c = apply_temperature_tint(c, Temperature, Tint, AdvancedTint, CustomTintColor, CustomTintStrength);
	c = apply_vibrance(c, Vibrance);
	c = apply_saturation(c, Saturation);
	c = apply_hue_shift(c, HueShift);
	// HSL Adjustments
	if (EnableHSL)
	{
		c = apply_hsl_adjustments(c);
	}
	
	// Channel Mixer
	if (EnableChannelMixer)
	{
		c = apply_channel_mixer(c);
	}

	// Tone
	c = apply_highlights_shadows(c, Highlights, Shadows);
	c = apply_clarity(uv, c, Clarity);
	c = apply_tone_curve(c, ToneCurve);
	
	// Color Grading
	if (EnableGrading)
	{
		c = apply_color_grading(c, GradingMode);
	}

	// LUT
	if (EnableLUT)
	{
		int lutSize = clamp(LUTSize, 16, 32);
		float3 lutc = sample_lut_strip(c, lutSize);
		c = lerp(c, lutc, LUTBlend);
	}
	
	// Bloom
	if (EnableBloom)
	{
		float3 bloom = apply_bloom(uv, c, BloomStrength, BloomRadius, BloomThreshold);
		c = bloom; // Store bloom result for lens dirt
		
		// Apply lens dirt if enabled (uses bloom as mask)
	}
	// Chromatic Aberration
	if (EnableCA)
	{
		c = apply_chromatic_aberration(uv, c, CARadius, CAIntensity);
	}
	
	// Film Grain
	if (EnableFilmGrain)
	{
		c = apply_film_grain(uv, c, GrainIntensity, GrainSize, FrameCount);
	}
	
	// Vignette (applied last)
	if (EnableVignette)
	{
		c = apply_vignette(uv, c, VignetteStyle, VignetteStrength, VignetteRadius, VignetteFeather, VignetteColor);
	}

	return saturate3(c);
}

// Bloom extraction pass
float3 PS_BloomExtract(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
	return threshold_color(color, BloomThreshold);
}

// Bloom blur pass
float3 PS_BloomBlur(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	float2 pixelSize = TEXEL_SIZE * BloomRadius;
	float3 blur = 0.0;
	
	for (int x = -2; x <= 2; x++)
	{
		for (int y = -2; y <= 2; y++)
		{
			float2 offset = float2(x, y) * pixelSize;
			blur += tex2D(sLaProw_BloomTex, texcoord + offset).rgb;
		}
	}
	
	return blur / 25.0;
}

// Main pass
float3 PS_LaProwFX(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
	return LaProw_Pipeline(texcoord);
}

// =================================================================================
// Technique
// =================================================================================
technique LaProwFX <
	ui_label   = "LaProwFX by LaProvidence";
	ui_tooltip = "Advanced photography FX";
>
{
	pass BloomExtract { VertexShader = PostProcessVS; PixelShader = PS_BloomExtract; RenderTarget = LaProw_BloomTex; }
	pass BloomBlur { VertexShader = PostProcessVS; PixelShader = PS_BloomBlur; RenderTarget = LaProw_BloomTex2; }
	pass { VertexShader = PostProcessVS; PixelShader = PS_LaProwFX; }
}