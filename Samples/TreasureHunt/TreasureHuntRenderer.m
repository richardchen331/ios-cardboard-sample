#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support. Compile with -fobjc-arc"
#endif

#define NUM_SLICES 50
#define NUM_PARALLELS (NUM_SLICES / 2)
#define NUM_VERTICIES ((NUM_PARALLELS + 1) * (NUM_SLICES + 1))
#define NUM_INDICES (NUM_PARALLELS * NUM_SLICES * 6)

#import "TreasureHuntRenderer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <GLKit/GLKit.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <QuartzCore/QuartzCore.h>

#import <math.h>

#import "GVRAudioEngine.h"
#import "GVRHeadTransform.h"

// Vertex shader implementation.
static const char *kVertexShaderString =
    "#version 100\n"
    "\n"
    "uniform mat4 uMVP; \n"
    "attribute vec3 aVertex; \n"
    "attribute vec2 aTexture;\n"
    "varying vec2 vTexture;\n"
    "void main(void) { \n"
    "  vec4 pos = vec4(aVertex, 1.0); \n"
    "  vTexture = aTexture;"
    "  gl_Position = uMVP * pos; \n"
    "    \n"
    "}\n";

// Fragment shader implementation.
static const char* kSphereFragmentShaderString =
    "#version 100\n"
    "\n"
    "#ifdef GL_ES\n"
    "precision mediump float;\n"
    "#endif\n"
    "varying vec2 vTexture;\n"
    "uniform sampler2D ourTexture;\n"
    "\n"
    "void main() {\n"
    "  gl_FragColor = texture2D(ourTexture, vTexture);\n"
    "}\n";

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

  // GL variables for the sphere.
  GLuint _sphere_program;
  GLint _sphere_vertex_attrib;
  GLint _sphere_texture_attrib;
  GLint _sphere_mvp_matrix;
  GLuint _sphere_vertex_buffer;
  GLuint _sphere_texture_buffer;
  GLuint _sphere_index_buffer;
}

#pragma mark - GVRCardboardViewDelegate overrides

- (void)cardboardView:(GVRCardboardView *)cardboardView
     willStartDrawing:(GVRHeadTransform *)headTransform {
  // Renderer must be created on GL thread before any call to drawFrame.
  // Load the vertex/fragment shaders.
  const GLuint vertex_shader = LoadShader(GL_VERTEX_SHADER, kVertexShaderString);
  NSAssert(vertex_shader != 0, @"Failed to load vertex shader");
  const GLuint sphere_fragment_shader = LoadShader(GL_FRAGMENT_SHADER, kSphereFragmentShaderString);
  NSAssert(sphere_fragment_shader != 0, @"Failed to load sphere fragment shader");

  /////// Create the program object for the sphere.

  _sphere_program = glCreateProgram();
  NSAssert(_sphere_program != 0, @"Failed to create program");
  glAttachShader(_sphere_program, vertex_shader);
  glAttachShader(_sphere_program, sphere_fragment_shader);
  glLinkProgram(_sphere_program);
  NSAssert(checkProgramLinkStatus(_sphere_program), @"Failed to link _sphere_program");

  // Get the location of our attributes so we can bind data to them later.
  _sphere_vertex_attrib = glGetAttribLocation(_sphere_program, "aVertex");
  NSAssert(_sphere_vertex_attrib != -1, @"glGetAttribLocation failed for aVertex");
  _sphere_texture_attrib = glGetAttribLocation(_sphere_program, "aTexture");
  NSAssert(_sphere_texture_attrib != -1, @"glGetAttribLocation failed for aTexture");

  // After linking, fetch references to the uniforms in our shader.
  _sphere_mvp_matrix = glGetUniformLocation(_sphere_program, "uMVP");
  NSAssert(_sphere_mvp_matrix != -1, @"Error fetching uniform values for shader.");

  float radius=99.9f; //Radius should be large but keep it between the near and far planes.
  int parallel;
  int slice;
  float angleStep = (2.0f * 3.1415926) / ((float) NUM_SLICES);

  GLfloat _sphere_vertices[3 * NUM_VERTICIES];
  GLfloat _sphere_textures[2 * NUM_VERTICIES];
  GLshort _sphere_indices[NUM_INDICES];

  for (parallel = 0; parallel < NUM_PARALLELS + 1; parallel++)
  {
    for (slice = 0; slice < NUM_SLICES + 1; slice++)
    {
      int vertex = (parallel * (NUM_SLICES + 1) + slice) * 3;
      _sphere_vertices[vertex + 0] = - radius * (float)sin(angleStep * (double)parallel) * (float)sin(angleStep * (double)slice);
      _sphere_vertices[vertex + 1] = - radius * (float)cos(angleStep * (double)parallel);
      _sphere_vertices[vertex + 2] = radius * (float)sin(angleStep * (double)parallel) * (float)cos(angleStep * (double)slice);
      int texIndex = (parallel * (NUM_SLICES + 1) + slice) * 2;
      _sphere_textures[texIndex + 0] = (1.0f - (float) slice / (float) NUM_SLICES);
      _sphere_textures[texIndex + 1] = (1.0f - (float) parallel  / (float) NUM_PARALLELS);
    }
  }
  // Generate the indices
  int thisIndex = 0;
  for ( parallel = 0; parallel < NUM_PARALLELS ; parallel++ )
  {
    for ( slice = 0; slice < NUM_SLICES; slice++ )
    {
      _sphere_indices[thisIndex] = (short)(parallel * (NUM_SLICES + 1) + slice);
      thisIndex++;
      _sphere_indices[thisIndex] = (short)((parallel + 1) * (NUM_SLICES + 1) + slice);
      thisIndex++;
      _sphere_indices[thisIndex] = (short)((parallel + 1) * (NUM_SLICES + 1) + (slice + 1));
      thisIndex++;

      _sphere_indices[thisIndex] = (short)(parallel * (NUM_SLICES + 1) + slice);
      thisIndex++;
      _sphere_indices[thisIndex] = (short)((parallel + 1) * (NUM_SLICES + 1) + (slice + 1));
      thisIndex++;
      _sphere_indices[thisIndex] = (short)(parallel * (NUM_SLICES + 1) + (slice + 1));
      thisIndex++;
    }
  }

  glGenBuffers(1, &_sphere_vertex_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, _sphere_vertex_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(_sphere_vertices), _sphere_vertices, GL_STATIC_DRAW);

  glGenBuffers(1, &_sphere_texture_buffer);
  glBindBuffer(GL_ARRAY_BUFFER, _sphere_texture_buffer);
  glBufferData(GL_ARRAY_BUFFER, sizeof(_sphere_textures), _sphere_textures, GL_STATIC_DRAW);

  glGenBuffers(1, &_sphere_index_buffer);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _sphere_index_buffer);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(_sphere_indices), _sphere_indices, GL_STATIC_DRAW);

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
  glUseProgram(_sphere_program);

  // Set the uniform matrix values that will be used by our shader.
  glUniformMatrix4fv(_sphere_mvp_matrix, 1, false, model_view_matrix);

  // Draw our polygons.
  glBindBuffer(GL_ARRAY_BUFFER, _sphere_vertex_buffer);
  glVertexAttribPointer(_sphere_vertex_attrib, 3, GL_FLOAT, GL_FALSE, sizeof(float) * 3, 0);
  glEnableVertexAttribArray(_sphere_vertex_attrib);

  glBindBuffer(GL_ARRAY_BUFFER, _sphere_texture_buffer);
  glVertexAttribPointer(_sphere_texture_attrib, 2, GL_FLOAT, GL_FALSE, sizeof(float) * 2, 0);
  glEnableVertexAttribArray(_sphere_texture_attrib);

  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _sphere_index_buffer);

  glDrawElements(GL_TRIANGLES, NUM_INDICES, GL_UNSIGNED_SHORT, 0);
  glDisableVertexAttribArray(_sphere_vertex_attrib);
}

- (void)cardboardView:(GVRCardboardView *)cardboardView shouldPauseDrawing:(BOOL)pause {
  if ([self.delegate respondsToSelector:@selector(shouldPauseRenderLoop:)]) {
    [self.delegate shouldPauseRenderLoop:pause];
  }
}

@end
