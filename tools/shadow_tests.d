// Standalone geometry/selection tests: ldc2 -Isource tools/shadow_tests.d source/dynamic_shadows.d
import DynamicShadows;
import std.math: abs;
import std.stdio: writeln;

float[4] Clip(const float[16] m, float[3] p) {
	float[4] c;
	foreach(r; 0..4) c[r]=m[r]*p[0]+m[4+r]*p[1]+m[8+r]*p[2]+m[12+r];
	return c;
}
void main() {
	immutable float[3][6] axes=[[1f,0f,0f],[-1f,0f,0f],[0f,1f,0f],[0f,-1f,0f],[0f,0f,1f],[0f,0f,-1f]];
	float[3] eye=[17f,-31f,53f];
	foreach(face; 0..6) {
		auto m=CubeFace(eye,400f,face);
		float[3] p;
		foreach(c; 0..3) p[c]=eye[c]+axes[face][c]*100f;
		auto clip=Clip(m,p);
		assert(abs(clip[0])<0.0001 && abs(clip[1])<0.0001);
		assert(abs(clip[3]-100f)<0.0001 && clip[2]/clip[3]>0 && clip[2]/clip[3]<1);
		float[3] low=p, high=p;
		low[]-=1f; high[]+=1f;
		assert(InFace(m,low,high));
		foreach(c; 0..3) p[c]=eye[c]-axes[face][c]*100f;
		low=p; high=p; low[]-=1f; high[]+=1f;
		assert(!InFace(m,low,high));
		foreach(c; 0..3) p[c]=eye[c]+axes[face][c]*NearPlane(400f);
		clip=Clip(m,p); assert(abs(clip[2]/clip[3])<0.0001);
		foreach(c; 0..3) p[c]=eye[c]+axes[face][c]*400f;
		clip=Clip(m,p); assert(abs(clip[2]/clip[3]-1f)<0.0001);
	}
	// A seam point is on the +X and +Z boundaries with equal radial depth.
	auto x=Clip(CubeFace([0f,0f,0f],400,0),[100f,0f,100f]);
	auto z=Clip(CubeFace([0f,0f,0f],400,4),[100f,0f,100f]);
	assert(abs(abs(x[0]/x[3])-1f)<0.0001 && abs(abs(z[0]/z[3])-1f)<0.0001);
	assert(InRadius([-10f,-10f,-10f],[10f,10f,10f],[20f,0f,0f],10f));
	assert(!InRadius([-10f,-10f,-10f],[10f,10f,10f],[20.1f,0f,0f],10f));
	// City Hub's entrance fence: its 129-unit sphere rejects lamp 297 although
	// the actual fence is only 16 units thick along this light ray.
	float[3] fence=[688f,-63.5f,2696f], half=[112f,63.5f,8f], lamp=[832f,-16f,2816f];
	auto far=BoundsFarPoint(fence,half,lamp);
	assert(abs(far[2]-2688f)<0.001f);
	float[3] delta=[far[0]-lamp[0],far[1]-lamp[1],far[2]-lamp[2]];
	import std.math: sqrt;
	assert(sqrt(delta[0]*delta[0]+delta[1]*delta[1]+delta[2]*delta[2])<210f);
	delta=[fence[0]-lamp[0],fence[1]-lamp[1],fence[2]-lamp[2]];
	assert(sqrt(delta[0]*delta[0]+delta[1]*delta[1]+delta[2]*delta[2])+129f>300f);
	// The far point stays on the box, including opposite rays, flat planes and a lamp at the centre.
	assert(BoundsFarPoint([0f,0f,0f],[2f,3f,4f],[10f,0f,0f])==[-2f,0f,0f]);
	assert(BoundsFarPoint([0f,0f,0f],[2f,3f,4f],[-10f,0f,0f])==[2f,0f,0f]);
	assert(BoundsFarPoint([0f,0f,0f],[2f,3f,0f],[0f,0f,10f])==[0f,0f,0f]);
	assert(BoundsFarPoint(fence,half,fence)==fence);
	float[16] identity=[1f,0f,0f,0f,0f,1f,0f,0f,0f,0f,1f,0f,0f,0f,0f,1f];
	assert(InView(identity,CubeFace([0f,0f,0f],400,4),[0f,0f,100f],10));
	assert(!InView(identity,CubeFace([0f,0f,0f],400,4),[0f,0f,-100f],10));
	struct Light { float[3] pos,colour; float radius; uint flags; size_t identity; }
	Light[] lights=[Light([0f,0f,50f],[255f,255f,255f],10,0,1),
		Light([0f,0f,51f],[255f,255f,255f],10,0,2),
		Light([0f,0f,-50f],[255f,255f,255f],10,0,3),
		Light([0f,0f,50f],[100f,100f,100f],10,0,4)];
	auto projection=CubeFace([0f,0f,0f],400,4);
	assert(SelectDynamicLights(lights,[0f,0f,0f],identity,projection,0,null).length==0);
	assert(SelectDynamicLights(lights,[0f,0f,0f],identity,projection,1,null)==[0u]);
	assert(SelectDynamicLights(lights,[0f,0f,0f],identity,projection,1,[cast(size_t)2])==[1u]);
	assert(SelectDynamicLights(lights,[0f,0f,0f],identity,projection,4,null)==[0u,1u]);
	Light[] close=[Light([0f,0f,10f],[255f,255f,255f],100,0,10),Light([0f,0f,80f],[255f,255f,255f],100,0,11)];
	assert(SelectDynamicLights(close,[0f,0f,0f],identity,projection,1,[cast(size_t)11])==[0u]);
	// All budgets pack six 256px faces/light into disjoint quadrants after the lamp tiles.
	foreach(count; 1..MaxDynamicShadows+1) {
		uint first=64-(count*6+3)/4;
		bool[256] occupied;
		foreach(unit; 0..count*6) {
			uint cell=first+unit/4, q=unit%4;
			uint slot=(cell/8*2+q/2)*16+(cell%8*2+q%2);
			assert(cell>=first && cell<64 && !occupied[slot]); occupied[slot]=true;
		}
	}
	writeln("shadow geometry: six faces, seams, clipping, bounds, selection, hysteresis and atlas budgets passed");
}
