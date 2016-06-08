#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support. Compile with -fobjc-arc"
#endif

#define NUM_GRID_VERTICES 18
#define NUM_GRID_COLORS 24
#define NUM_GRID_TEXTURES 12

#import "TreasureHuntRenderer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>

#import "GVRAudioEngine.h"
#import "GVRHeadTransform.h"

// Vertex shader implementation.
static const char *kVertexShaderString =
    "#version 100\n"
    "\n"
    "uniform mat4 uMVP; \n"
    "uniform vec3 uPosition; \n"
    "attribute vec3 aVertex; \n"
    "attribute vec4 aColor;\n"
    "attribute vec2 aTexture;\n"
    "varying vec4 vColor;\n"
    "varying vec2 vTexture;\n"
    "void main(void) { \n"
    "  vec4 pos = vec4(aVertex + uPosition, 1.0); \n"
    "  vColor = aColor;"
    "  vTexture = aTexture;"
    "  gl_Position = uMVP * pos; \n"
    "    \n"
    "}\n";

// Fragment shader for the floorplan grid.
static const char* kGridFragmentShaderString =
    "#version 100\n"
    "\n"
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "varying vec4 vColor;\n"
    "varying vec2 vTexture;\n"
    "uniform sampler2D ourTexture;\n"
    "\n"
    "void main() {\n"
    "  gl_FragColor = texture2D(ourTexture, vTexture);\n"
    "}\n";

static const float kGridVertices[NUM_GRID_VERTICES] = {
  200.0f, 0.0f, -200.0f,
  -200.0f, 0.0f, -200.0f,
  -200.0f, 0.0f, 200.0f,
  200.0f, 0.0f, -200.0f,
  -200.0f, 0.0f, 200.0f,
  200.0f, 0.0f, 200.0f,
};

static const float kGridColors[NUM_GRID_COLORS] = {
  0.0f, 0.3398f, 0.9023f, 1.0f,
  0.0f, 0.3398f, 0.9023f, 1.0f,
  0.0f, 0.3398f, 0.9023f, 1.0f,
  0.0f, 0.3398f, 0.9023f, 1.0f,
  0.0f, 0.3398f, 0.9023f, 1.0f,
  0.0f, 0.3398f, 0.9023f, 1.0f,
};

static const float kGridTextures[NUM_GRID_TEXTURES] = {
    1.0f, 1.0f,
    0.0f, 1.0f,
    0.0f, 0.0f,
    1.0f, 1.0f,
    0.0f, 0.0f,
    1.0f, 0.0f,
};

static GLuint LoadShader(GLenum type, const char *shader_src) {
  GLint compiled = 0;

  // Create the shader object
  const GLuint shader = glCreateShader(type);
  // Load the shader source
  glShaderSource(shader, 1, &shader_src, NULL);

  // Compile the shader
  glCompileShader(shader);
  // Check the compile status
  glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);

  if (!compiled) {
    GLint info_len = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &info_len);

    if (info_len > 1) {
      char *info_log = ((char *)malloc(sizeof(char) * info_len));
      glGetShaderInfoLog(shader, info_len, NULL, info_log);
      NSLog(@"Error compiling shader:%s", info_log);
      free(info_log);
    }
    glDeleteShader(shader);
    return 0;
  }

  return shader;
}

// Checks the link status of the given program.
static bool checkProgramLinkStatus(GLuint shader_program) {
  GLint linked = 0;
  glGetProgramiv(shader_program, GL_LINK_STATUS, &linked);

  if (!linked) {
    GLint info_len = 0;
    glGetProgramiv(shader_program, GL_INFO_LOG_LENGTH, &info_len);

    if (info_len > 1) {
      char *info_log = ((char *)malloc(sizeof(char) * info_len));
      glGetProgramInfoLog(shader_program, info_len, NULL, info_log);
      NSLog(@"Error linking program: %s", info_log);
      free(info_log);
    }
    glDeleteProgram(shader_program);
    return false;
  }
  return true;
}

@implementation TreasureHuntRenderer {

  // GL variables for the grid.
  GLfloat _grid_vertices[NUM_GRID_VERTICES];
  GLfloat _grid_colors[NUM_GRID_COLORS];
  GLfloat _grid_textures[NUM_GRID_TEXTURES];
  GLfloat _grid_position[3];

  GLuint _grid_program;
  GLint _grid_vertex_attrib;
  GLint _grid_color_attrib;
  GLint _grid_texture_attrib;
  GLint _grid_position_uniform;
  GLint _grid_mvp_matrix;
  GLuint _grid_vertex_buffer;
  GLuint _grid_color_buffer;
  GLuint _grid_texture_buffer;
}

#pragma mark - GVRCardboardViewDelegate overrides

- (void)cardboardView:(GVRCardboardView *)cardboardView
     willStartDrawing:(GVRHeadTransform *)headTransform {
  // Renderer must be created on GL thread before any call to drawFrame.
  // Load the vertex/fragment shaders.
  const GLuint vertex_shader = LoadShader(GL_VERTEX_SHADER, kVertexShaderString);
  NSAssert(vertex_shader != 0, @"Failed to load vertex shader");
  const GLuint grid_fragment_shader = LoadShader(GL_FRAGMENT_SHADER, kGridFragmentShaderString);
  NSAssert(grid_fragment_shader != 0, @"Failed to load grid fragment shader");

  /////// Create the program object for the grid.

  _grid_program = glCreateProgram();
  NSAssert(_grid_program != 0, @"Failed to create program");
  glAttachShader(_grid_program, vertex_shader);
  glAttachShader(_grid_program, grid_fragment_shader);
  glLinkProgram(_grid_program);
  NSAssert(checkProgramLinkStatus(_grid_program), @"Failed to link _grid_program");

  // Get the location of our attributes so we can bind data to them later.
  _grid_vertex_attrib = glGetAttribLocation(_grid_program, "aVertex");
  NSAssert(_grid_vertex_attrib != -1, @"glGetAttribLocation failed for aVertex");
  _grid_color_attrib = glGetAttribLocation(_grid_program, "aColor");
  NSAssert(_grid_color_attrib != -1, @"glGetAttribLocation failed for aColor");
  _grid_texture_attrib = glGetAttribLocation(_grid_program, "aTexture");
  NSAssert(_grid_texture_attrib != -1, @"glGetAttribLocation failed for aTexture");

  // After linking, fetch references to the uniforms in our shader.
  _grid_mvp_matrix = glGetUniformLocation(_grid_program, "uMVP");
  _grid_position_uniform = glGetUniformLocation(_grid_program, "uPosition");
  NSAssert(_grid_mvp_matrix != -1 && _grid_position_uniform != -1,
           @"Error fetching uniform values for shader.");

  // Position grid below the camera.
  _grid_position[0] = 0;
  _grid_position[1] = -20.0f;
  _grid_position[2] = 0;

  for (int i = 0; i < NUM_GRID_VERTICES; ++i) {
    _grid_vertices[i] = (GLfloat)(kGridVertices[i]);
  }
  glGenBuffers(1, &_grid_vertex_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, _grid_vertex_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(_grid_vertices), _grid_vertices, GL_STATIC_DRAW);

  // Initialize the color data for the grid mesh.
  for (int i = 0; i < NUM_GRID_COLORS; ++i) {
    _grid_colors[i] = (GLfloat)(kGridColors[i]);
  }
  glGenBuffers(1, &_grid_color_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, _grid_color_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(_grid_colors), _grid_colors, GL_STATIC_DRAW);

  for (int i = 0; i < NUM_GRID_TEXTURES; ++i) {
    _grid_textures[i] = (GLfloat)(kGridTextures[i]);
  }
  glGenBuffers(1, &_grid_texture_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, _grid_texture_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(_grid_textures), _grid_textures, GL_STATIC_DRAW);

  GLKTextureInfo *spriteTexture;
  NSError *theError;
  NSString *filePath = [[NSBundle mainBundle] pathForResource:@"360_image" ofType:@"jpg"];
  spriteTexture = [GLKTextureLoader textureWithContentsOfFile:filePath options:nil error:&theError];
  glBindTexture(spriteTexture.target, spriteTexture.name);
}

- (void)cardboardView:(GVRCardboardView *)cardboardView
     prepareDrawFrame:(GVRHeadTransform *)headTransform {

  // Clear GL viewport.
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glEnable(GL_DEPTH_TEST);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
  glEnable(GL_SCISSOR_TEST);
}

- (void)cardboardView:(GVRCardboardView *)cardboardView
              drawEye:(GVREye)eye
    withHeadTransform:(GVRHeadTransform *)headTransform {
  CGRect viewport = [headTransform viewportForEye:eye];
  glViewport(viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height);
  glScissor(viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height);

  // Get the head matrix.
  const GLKMatrix4 head_from_start_matrix = [headTransform headPoseInStartSpace];

  // Get this eye's matrices.
  GLKMatrix4 projection_matrix = [headTransform projectionMatrixForEye:eye near:0.1f far:100.0f];
  GLKMatrix4 eye_from_head_matrix = [headTransform eyeFromHeadMatrix:eye];

  // Compute the model view projection matrix.
  GLKMatrix4 model_view_projection_matrix = GLKMatrix4Multiply(
      projection_matrix, GLKMatrix4Multiply(eye_from_head_matrix, head_from_start_matrix));

  // Render from this eye.
  [self renderWithModelViewProjectionMatrix:model_view_projection_matrix.m];
}

- (void)renderWithModelViewProjectionMatrix:(const float *)model_view_matrix {

  // Select our shader.
  glUseProgram(_grid_program);

  // Set the uniform values that will be used by our shader.
  glUniform3fv(_grid_position_uniform, 1, _grid_position);

  // Set the uniform matrix values that will be used by our shader.
  glUniformMatrix4fv(_grid_mvp_matrix, 1, false, model_view_matrix);

  // Set the grid colors.
  glBindBuffer(GL_ARRAY_BUFFER, _grid_color_buffer);
  glVertexAttribPointer(_grid_color_attrib, 4, GL_FLOAT, GL_FALSE, sizeof(float) * 4, 0);
  glEnableVertexAttribArray(_grid_color_attrib);

  // Draw our polygons.
  glBindBuffer(GL_ARRAY_BUFFER, _grid_vertex_buffer);
  glVertexAttribPointer(_grid_vertex_attrib, 3, GL_FLOAT, GL_FALSE, sizeof(float) * 3, 0);
  glEnableVertexAttribArray(_grid_vertex_attrib);

  glBindBuffer(GL_ARRAY_BUFFER, _grid_texture_buffer);
  glVertexAttribPointer(_grid_texture_attrib, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 2, 0);
  glEnableVertexAttribArray(_grid_texture_attrib);

  glDrawArrays(GL_TRIANGLES, 0, NUM_GRID_VERTICES / 3);
  glDisableVertexAttribArray(_grid_vertex_attrib);
}

- (void)cardboardView:(GVRCardboardView *)cardboardView shouldPauseDrawing:(BOOL)pause {
  if ([self.delegate respondsToSelector:@selector(shouldPauseRenderLoop:)]) {
    [self.delegate shouldPauseRenderLoop:pause];
  }
}

@end
