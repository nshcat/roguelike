//===-- ascii.vs.glsl - Main vertex shader ---------------------*- GLSL -*-===//
//
//                     			 gl_app
//
// This file is distributed under the MIT Open Source License.
// See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file contains the main vertex shader for the ascii graphics engine.
//
// It implements calculation of glyph texture coordinates, shadow intensity
// and lighting and forwards that data to the fragment shader.
// Note that this shader receives no actual geometry - all vertex data is
// calculated "just-in-time" by this shader. The calling program uses instanced
// drawing to cause the GPU to execute this shader six times per glyph position
// (two triangles to form one quad).
//
//===----------------------------------------------------------------------===//
// TODO:
//  - Use interface blocks for smooth and flat output data
//  - Use one global CellData instance to store cell data
//  - To implement fog: Change fog value in input buffer to "depth", a value
//    that can be both used for fog calulation aswell as lighting (should be
//    integral)
//  - Lighting should not light the drop shadows!
//  - Lighting needs to use 3D norm for distance, using the stored "depth"
//    value
//  - The gui_mode bit should result in the cell being lit 100%, but being used
//    like a "normal" cell for lighting calculations
//  - Add two ambient light values: inside and outside. This would require a bit
//    to indicate whether a certain cell is inside or outside.
//
//===----------------------------------------------------------------------===//

#version 450

//===----------------------------------------------------------------------===//
// Constants and macros
//

// Drop shadow orientation bit positions. A cell may have any combination of
// them. They will be rendered on-top of each other.
#define SHADOW_N 	0x1 << 8
#define SHADOW_W 	0x1 << 9
#define SHADOW_S 	0x1 << 10
#define SHADOW_E 	0x1 << 11
#define SHADOW_TL 	0x1 << 12
#define SHADOW_TR 	0x1 << 13
#define SHADOW_BL 	0x1 << 14
#define SHADOW_BR 	0x1 << 15

// Shadow bit mask, contains shadow orientation bit field
#define SHADOW_MASK 0xFF00

// Light modes. These are used to determine how a cell reacts to lighting.
#define LIGHT_NONE 	0	//< Block light. Stays completely dark.
#define LIGHT_DIM 	1	//< Block light. Receive small amount of light.
#define LIGHT_FULL 	2	//< Don't block light. Receive full amount of light.

// Mask and shift for light mode value
#define LIGHT_MASK 	0xF0000
#define LIGHT_SHIFT 16

// Gui mode bit position
#define GUI_MODE 0x1 << 20

// Mask for fog percentage value
#define FOG_MASK 0xFF

// Cursor bit position
#define CURSOR 0x1 << 16

// Maximum number of lights allowed in the light data uniform
#define MAX_LIGHTS 25

// Glyph texture offsets from the top left for the 6 vertices of a cell.
const vec2 texture_offset[] = vec2[6](
	vec2(1, 1),	// BR
	vec2(1, 0),	// TR
	vec2(0, 0),	// TL
	
	vec2(1, 1),	// BR
	vec2(0, 0),	// TL
	vec2(0, 1)	// BL
);

// Drop shadow coordinates of the first shadow element for the 6 vertices of
// the cell
const vec2 shadow_coords[] = vec2[6](
	vec2(1.f/8.f, 1),	// BR
	vec2(1.f/8.f, 0),	// TR
	vec2(0, 0),			// TL
	
	vec2(1.f/8.f, 1),	// BR
	vec2(0, 0),			// TL
	vec2(0, 1)			// BL
);

// Offset from top left vertex for each of the six vertices of the cell quad.
// These are used to calculate the vertex data for every shader call.
const vec2 vertex_offset[] = vec2[6](
	vec2(1, 1),	// BR
	vec2(1, 0),	// TR
	vec2(0, 0),	// TL
	
	vec2(1, 1),	// BR
	vec2(0, 0),	// TL
	vec2(0, 1)	// BL
);

//===----------------------------------------------------------------------===//





//===----------------------------------------------------------------------===//
// Struct definitions
//

// Struct containing all information a light source has
struct Light
{
	ivec2 position;		// ┐	//< Position in the game world TODO if something breaks revert this to "vec2"
	float intensity;	// │	//< Intensity of the light source
	bool  use_radius;	// ┘	//< Calculate att. factors based on radius
	vec4  color;		// 		//< Color of the light
	vec3  att_factors;	// ┐	//< Factors used in attenuation function
	float radius;		// ┘	//< Radius of illumination
};

// Struct containg global state of the lighting system
struct LightingState
{
	bool use_lighting;	// ┐	//< Global lighting enable/disable
	bool use_dynamic;	// │	//< Dynamic lighting enable/disable
	vec2 tl_position;	// ┘	//< Absolute position of the top left corner
	vec4 ambient;		//		//< Global ambient illumination
};

// Struct containg all data that can be extracted from a cell entry in
// the input buffer
struct CellData
{
	vec2 screen_coords;		//< Screen coordinates of cell in glyphs
	vec4 front_color;		//< Front color of the glyph
	vec4 back_color;		//< Back color of the glyph
	vec2 glyph;				//< Glyph coordinates on glyph sheet
	float fog_percentage;	//< Fog percentage value
	uint shadows[8];		//< Array of shadow orientation flags
	uint light_mode;		//< Light calulation mode
	bool gui_mode;			//< Act like a normal tile for light calculations,
							//  but be fully lit (for GUI elements that overlap
							//  lit scenery)
};

//===----------------------------------------------------------------------===//





//===----------------------------------------------------------------------===//
// Uniform Data
//

// Buffer containg screen data.
//
// Every cell is described by two uvec4 instances in the buffer.
// Format: (fr,fg,fb,glyph)(br,bg,bb,data)
//
// With data being composed as follows:
//
// FF 000 0  F  0  0  0  0  0 0 0 0 FF
//        ^  ^  ^  ^  ^  ^  ^ ^ ^ ^ ^
//        GM LM BR BL TR TL E S W N fog
//	            └──Drop Shadows───┘  
//
uniform usamplerBuffer input_buffer;


// Buffer containg all lights to use in lighting calculations
layout (std140, binding = 0) uniform light_data
{
	LightingState state;
	Light lights[MAX_LIGHTS];
	uint num_lights;
};


// Miscellaneous uniforms
uniform ivec2 glyph_dimensions;	//< Dimensions of a single glyph in pixels
uniform ivec2 sheet_dimensions;	//< Dimensions of glyph sheet in glyphs
uniform ivec2 glyph_count;		//< Screen size in glyphs
uniform mat4 projection_mat;	//< Projection matrix
uniform float fog_density;		//< Density value for fog calculation
uniform ivec2 cursor_pos;		//< Position of cursor, in screen coordinates

//===----------------------------------------------------------------------===//




//===----------------------------------------------------------------------===//
// Output data
//

// Flat output data (no interpolation)
out vs_flat_out
{
	flat vec4 front_color;		//< Foreground color of glyph
	flat vec4 back_color;		//< Background color of glyph
	flat float fog_factor;		//< Fog interpolation value [0, 1]
	flat uint[8] shadows;		//< Array of shadow orientation flags
	flat int has_cursor;		//< Flag indicating presence of cursor
	flat uint light_mode;		//< How this cell should react to light
	flat uint gui_mode;			//< Flag indicating GUI mode (see CellData)
	flat vec4 lighting_result;	//< Color representing result of lighting
								//  calculations. Is blended in with colored
								//  glyph texture in fragment shader.
} flat_out;


// Smooth output data
out vs_smooth_out
{
	smooth vec2 tex_coords;		//< Glyph texture coordinates for cell
	smooth vec2 cursor_coords;	//< Cursor texture coordinates for cell
	smooth vec2 shadow_coords;	//< Shadow texture coordinates. This actually
								//  references the leftmost shadow texture,
								//  but will be offset in fragment shader
								//  to blend all needed orientations together.
} smooth_out;

//===----------------------------------------------------------------------===//




//===----------------------------------------------------------------------===//
// Global variables
//

// Information about the currently handled cell
CellData this_cell;

//===----------------------------------------------------------------------===//




//===----------------------------------------------------------------------===//
// Subroutines
//

// Reads data of this cell and saves it to the global cell info variable
void read_cell()
{
	// Determine screen coordinates of this cell
	this_cell.screen_coords = vec2(
		gl_InstanceID % glyph_count.x,
		gl_InstanceID / glyph_count.x
	);
	
	// Retrieve the two uvec4 containing all cell data
	const uvec4 t_high = texelFetch(input_buffer, gl_InstanceID*2);
	const uvec4 t_low = texelFetch(input_buffer, (gl_InstanceID*2)+1);
	
	// Retrieve front and back color
	this_cell.front_color = vec4(vec3(t_high.rgb) / 255.f, 1.f);
	this_cell.back_color = vec4(vec3(t_low.rgb) / 255.f, 1.f);
	
	// Retrieve glyph coordinates
	this_cell.glyph = vec2(
		t_high.a % sheet_dimensions.x,
		t_high.a / sheet_dimensions.x
	);
	
	// Retrieve fog percentage
	// There is no need to shift here, since the fog component starts with
	// the LSB
	this_cell.fog_percentage = float(t_low.a & FOG_MASK) / 255.f;
	
	// Check if gui mode bit is set
	this_cell.gui_mode = ( (t_low.a & GUI_MODE) != 0.f ? 1 : 0 );
	
	// Retrieve light mode
	this_cell.light_mode = read_lm(t_low.a);
	
	// Read drop shadow orientations
	read_shadows(t_low.a);
}

// Retrieve light mode
// This does not directly assign to this_cell because it is also used
// by lighting calculations to detect objects that block the light ray
uint read_lm(in uint p_in)
{
	return (p_in & LIGHT_MASK) >> LIGHT_SHIFT;
}

// Retrieve drop shadow orientations
void read_shadows(in uint p_in)
{
	this_cell.shadows = uint[8]
	(
		p_in & SHADOW_W,
		p_in & SHADOW_S,
		p_in & SHADOW_N,
		p_in & SHADOW_E,	
		p_in & SHADOW_BR,
		p_in & SHADOW_BL,
		p_in & SHADOW_TL,
		p_in & SHADOW_TR
	);
}

// Calculate vertex for this shader call
void emit_vertex()
{
	// Calculate absolute (in world space) top left coordinates of this cell
	vec2 t_tl = this_cell.screen_coords * vec2(glyph_dimensions);
	
	// Add offset for vertices that are not the top left one
	t_tl += vertex_offset[gl_VertexID] * vec2(glyph_dimensions);
	
	// Create homogenous 4D vector and transform using projection matrix,
	// which implements an orthographic view frustum where the y-axis is flipped.
	// This allows us to use "screen-like" coordinates (with the origin being 
	// the top left corner of the screen, and the y-axis growing downwards)
	// in world space.
	gl_Position = projection_mat * vec4(t_tl, 0.f, 1.f);	
}

// Calculate texture coordinates for this cell
void calc_tex_coords()
{
	// Dimension of a single glyph texture in texture space (UV)
	const vec2 t_dimTex = vec2(1.f/sheet_dimensions.x, 1.f/sheet_dimensions.y);
	
	// Calculate texture coordinates of top left vertex
	vec2 t_tl = t_dimTex * this_cell.glyph;
	
	// If this vertex is in fact not the top left one, we need to add an offset
	// to calculate the texture coordinates.
	// This is simply done by adding the offset (which is either 0 or 1 in both
	// x and y direction) multiplied by the size of one glyph in texture space.
	// We will receive one of the four corners of the glyph texture.
	t_tl += texture_offset[gl_VertexID] * t_dimTex;
	
	// Write value to output interface block
	smooth_out.tex_coords = t_tl;
}

void calc_shadow_coords()
{
	// Lookup value and write to output interface block
	smooth_out.shadow_coords = shadow_coords[gl_VertexID];
}

void calc_fog()
{
	// Standard exponential distance fog equation
	const float t_fogFactor = exp(-fog_density * this_cell.fog_percentage);
	
	flat_out.fog_factor = clamp(t_fogFactor, 0.f, 1.f);
}

void calc_lighting()
{
	if(light_data.state.use_lighting && light_data.state.use_dynamic 
		&& (this_cell.lighting_mode != LIGHT_NONE))
	{
		// Calculate absolute position of cell in game world
		const ivec2 t_cellPos = ivec2(this_cell.screen_coords + 
			light_data.state.tl_position);
			
		// Initialize destination color
		vec4 t_lightColor = vec4(0.f);
		
		// Process all lights
		for(uint t_index = 0; t_index < light_data.num_lights; ++t_index)
		{
			// Fetch current light
			Light t_light = light_data.lights[t_index];
			
			// Check if light is visible
			if(!visible(t_cellPos, t_light.position))
				continue;
				
			// Calculate distance to light
			const float t_dist = length(t_cellPos - t_light.position);
			
			// Calculate intensity using light attenuation function
			float t_intensity = 0.f;
			
			if(t_light.use_radius)
			{
				// Use radius to calculate falloff
				t_intensity = 1.f / (1.f + ((2.f/t_light.radius)*t_dist)
						+ (1.f/pow(t_light.radius, 2.f))*pow(t_dist, 2.0f));
			}
			else
			{
				// Use given attenuation factors to calculate falloff
				t_intensity = 1.f / (t_light.att_factors.x
						+ (t_light.att_factors.y*t_dist)
						+ (t_light.att_factors.z*pow(t_dist, 2.0f)));
			}
			
			// Clamp intensity, since at short distances the attenuation
			// function gets infinitely big
			t_intensity = min(t_intensity, 1.f);
			
			// Add to accumulated light color
			t_lightColor += (t_intensity * t_light.intensity) * t_light.color;
			t_lightColor.a = 1.f;
		}
		
		// Output calculated light color
		flat_out.lighting_result = t_lightColor;
	}
}
//===----------------------------------------------------------------------===//




//===----------------------------------------------------------------------===//
// Shader entry point
//
void main()
{
	// Read cell data
	read_cell();
	
	// Create vertex depending on current vertex ID
	emit_vertex();
	
	// Calculate glyph texture coordinates for this cell
	calc_tex_coords();
	
	// Calculate shadow coordinates for this cell
	calc_shadow_coords();
	
	// Calculate fog
	calc_fog();
	
	// Do lighting
	calc_lighting();
	
	// Write remaining data to output interface blocks
	write_data();
}
//===----------------------------------------------------------------------===//




