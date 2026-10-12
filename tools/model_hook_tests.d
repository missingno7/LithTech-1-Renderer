// CPU-only integration fixture. No window, SDL initialization or Vulkan calls.
module ModelHookTests;
import ModelDraw;
import LTObjects;
import RendererTypes;
import RendererCompat: ModelWarble;
import SceneGeometry;
import Objects.BaseObject: ObjectType;
import Texture;
import VulkanRender: VulkanRenderer;
import Main;
import std.math: abs;
import std.stdio: writeln;

uint hooks;
extern(C) void NoTexture(ModelHookData* data, void*)
{
	++hooks;
	assert(data.flags==ModelHookFlags.UseTexture);
	data.flags=cast(ModelHookFlags)0;
	data.object_flags=cast(typeof(data.object_flags))(cast(uint)data.object_flags | ObjectFlag.Shadow);
	data.light_add.x=64f;
}
extern(C) void* GetVar(const char* name)
{
	import std.string: fromStringz;
	return name.fromStringz=="DrawModels" ? cast(void*)1 : name.fromStringz=="DrawEnable" ? cast(void*)2 : null;
}
bool enable=true;
extern(C) float GetFloat(void* variable) { return variable==cast(void*)2 && enable ? 1f : 0f; }

void main()
{
	ubyte[0x180] object_storage=0;
	ubyte[0xd0] model=0;
	ubyte[0x74] anim=0;
	auto object=cast(LTObject*)object_storage.ptr;
	object.flags=ObjectFlag.Visible | ObjectFlag.NoLight;
	object.type=cast(byte)ObjectType.Model;
	object.a=255;
	object.pos[]=0f; object.rot=[0f,0f,0f,1f]; object.scale[]=1f;
	At!(void*)(object,ModelDataOffset)=model.ptr;
	At!(void*)(object,ModelPrevAnimOffset)=anim.ptr;
	At!(void*)(object,ModelCurAnimOffset)=anim.ptr;
	At!(void*)(object,ModelSkinOffset)=cast(void*)0x1234; // must never be resolved when the hook disables texturing
	At!float(object,ModelBlendOffset)=0f;
	At!uint(model.ptr,ModelMatrixCountOffset)=1;
	ModelVertex[4] vertices;
	foreach(ref v; vertices) { v.pos[]=0f; v.nx=127; v.ny=0; v.nz=0; v.node=0; }
	vertices[0].pos=[1f,0f,0f]; vertices[1].pos=[0f,1f,0f]; vertices[2].pos=[0f,0f,1f]; vertices[3].pos=[1f,1f,0f];
	ModelFace[2] faces;
	faces[0].vertex=[0,1,2]; faces[1].vertex=[0,2,3];
	faces[0].node_visibility=0; faces[1].node_visibility=0;
	float[12] uv=0f;
	At!(ModelVertex*)(model.ptr,ModelVerticesOffset)=vertices.ptr;
	At!uint(model.ptr,ModelVertexCountOffset)=4;
	At!(ModelFace*)(model.ptr,ModelFacesOffset)=faces.ptr;
	At!uint(model.ptr,ModelFaceCountOffset)=2;
	At!(float*)(model.ptr,ModelFaceUVsOffset)=uv.ptr;
	SceneDesc scene;
	scene.global_light_scale.vector=[1f,1f,1f];
	scene.model_light_add[]=0f; scene.model_dir_add[]=0f;
	scene.model_hook_fnc_ptr=&NoTexture;
	ObjectGeometry geometry;
	ModelWarble warp;
	warp.EndScene(.02f,25f,.92f);
	DrawModel(geometry,object,&scene,null,[1f,0f,0f],null,null,null,&warp,
		(SharedTexture*) { assert(false,"disabled skin was resolved"); return RenderTexture.init; });
	assert(hooks==1 && geometry.vertices.length==6);
	assert(geometry.groups[DrawGroup.SolidModels].length==1);
	assert(geometry.groups[DrawGroup.SolidModels][0].mode==TextureMode.Untextured);
	assert(geometry.groups[DrawGroup.SolidModels][0].lighting.kind==LightingKind.Model);
	assert(abs(geometry.vertices[0].pos[0]-warp.Scale(0))<.00001f);
	assert(geometry.vertices[0].pos==geometry.vertices[3].pos);
	assert(geometry.vertices[2].pos==geometry.vertices[4].pos);
	assert(object.flags==(ObjectFlag.Visible | ObjectFlag.NoLight)); // hook flags are per draw
	assert(abs(geometry.groups[DrawGroup.SolidModels][0].lighting.ambient[0]-64f/255f)<.00001f);
	assert(g_ShadowStats[0]==1); // hook's per-draw shadow flag reaches the backend
	scene.model_hook_fnc_ptr=null;
	ObjectGeometry textured;
	bool resolved;
	DrawModel(textured,object,&scene,null,[1f,0f,0f],null,null,null,null,
		(SharedTexture* skin) { assert(skin==cast(SharedTexture*)0x1234); resolved=true; return RenderTexture.init; });
	assert(resolved && textured.groups[DrawGroup.SolidModels][0].mode==TextureMode.Normal);

	// The real scene entry/collector must bypass models, even in object-list mode.
	RenderDLL api;
	api.GetConsoleVar=&GetVar; api.GetVarValueFloat=&GetFloat;
	Main._renderer=&api;
	Main.g_RenderContext=null;
	LTObject*[1] objects=[object];
	scene.draw_mode=DrawMode.ObjectList;
	scene.obj_list_head=cast(void**)objects.ptr; scene.obj_count=1;
	scene.model_hook_fnc_ptr=&NoTexture;
	scene.camera_position.vector[]=0f; scene.camera_rotation=[0f,0f,0f,1f];
	scene.frame_delta=0f; scene.fov_x=1.57f; scene.fov_y=1.2f;
	hooks=0;
	auto renderer=new VulkanRenderer;
	renderer.RenderScene(&scene); // DrawModels=0
	assert(hooks==0);
	enable=false;
	scene.obj_list_head=cast(void**)1; // DrawEnable=0 must not inspect any supplied objects
	renderer.RenderScene(&scene);
	writeln("model integration: hook flags/light, untextured lit batches, shared warble vertices and render gates passed");
}
