module DynamicShadows;

// Omnidirectional lights use six 90-degree views in subtiles of the existing lamp atlas.
// Matrices and tile rectangles are shared verbatim by rasterization and receiver sampling.
import std.math: sqrt, abs, isFinite;
import std.algorithm: min, max, sort;

enum uint MaxDynamicShadows=4;
struct GpuDynamicShadow
{
	uint[4] info; // light-list index, remaining fields reserved
	float[16][6] view_proj;
	float[4][6] tile; // xy origin, z size, w near plane
}
static assert(GpuDynamicShadow.sizeof==496);

float[16] CubeFace(const float[3] eye, float radius, uint face)
{
	static immutable float[3][6] directions=[[1f,0f,0f],[-1f,0f,0f],[0f,1f,0f],[0f,-1f,0f],[0f,0f,1f],[0f,0f,-1f]];
	const float[3] forward=directions[face];
	const float[3] hint=face==2 || face==3 ? [0f,0f,1f] : [0f,1f,0f];
	const float[3] right=Cross(hint, forward), up=Cross(forward, right); // cardinal axes, already unit length
	const float near=NearPlane(radius), a=radius/(radius-near), b=-radius*near/(radius-near);
	float[16] m;
	foreach(c; 0..3) { m[c*4]=right[c]; m[c*4+1]=up[c]; m[c*4+2]=forward[c]*a; m[c*4+3]=forward[c]; }
	m[12]=-Dot(right, eye); m[13]=-Dot(up, eye); m[14]=-Dot(forward, eye)*a+b; m[15]=-Dot(forward, eye);
	return m;
}
float NearPlane(float radius) { return max(0.25f, min(1f, radius*0.002f)); }

// Conservative sphere/frustum intersection: tests the six unnormalised clip planes.
bool InView(const float[16] view, const float[16] proj, const float[3] p, float radius)
{
	float[16] m;
	m[]=0f;
	foreach(c; 0..4) foreach(r; 0..4) foreach(k; 0..4) m[c*4+r]+=proj[k*4+r]*view[c*4+k];
	foreach(plane; 0..6) {
		float[4] eq;
		foreach(c; 0..4) {
			if (plane==4) eq[c]=m[c*4+2];
			else if (plane==5) eq[c]=m[c*4+3]-m[c*4+2];
			else eq[c]=m[c*4+3]+(plane%2==0 ? 1f : -1f)*m[c*4+plane/2];
		}
		float d=eq[0]*p[0]+eq[1]*p[1]+eq[2]*p[2]+eq[3];
		if (d < -radius*sqrt(eq[0]*eq[0]+eq[1]*eq[1]+eq[2]*eq[2])) return false;
	}
	return true;
}

// Object identity gives incumbents a small hysteresis bonus. Recompute transforms each frame;
// no stale depth or retained allocation survives a moving/disappearing light or level change.
uint[] SelectDynamicLights(Light)(const Light[] lights, const float[3] camera, const float[16] view,
	const float[16] proj, uint budget, const size_t[] previous)
{
	struct Candidate { uint index; float score; }
	Candidate[] candidates;
	foreach(i, ref l; lights[0..min($, 40)]) {
		if (!isFinite(l.radius) || l.radius<2f || !InView(view, proj, l.pos, l.radius)) continue;
		float intensity=max(l.colour[0], max(l.colour[1], l.colour[2]))/127.5f-1f;
		if (intensity<=0.01f) continue;
		float[3] delta=[l.pos[0]-camera[0],l.pos[1]-camera[1],l.pos[2]-camera[2]];
		float distance=sqrt(Dot(delta, delta));
		float influence=l.radius/max(distance, l.radius);
		// Near flashes must outrank an incumbent lamp even when both spheres cover the eye.
		float proximity=1f/(1f+distance/l.radius);
		float score=intensity*influence*influence*proximity;
		foreach(id; previous) if (id==l.identity && id!=0) { score*=1.2f; break; }
		candidates~=Candidate(cast(uint)i, score);
	}
	candidates.sort!((a,b) => a.score==b.score ? a.index<b.index : a.score>b.score);
	uint[] result;
	foreach(ref c; candidates[0..min($, min(budget, MaxDynamicShadows))]) result~=c.index;
	return result;
}

// AABB/sphere overlap; level bounds are built once and never depend on camera visibility.
bool InRadius(const float[3] low, const float[3] high, const float[3] eye, float radius)
{
	float d2=0;
	foreach(c; 0..3) { float d=max(low[c]-eye[c], max(eye[c]-high[c], 0f)); d2+=d*d; }
	return d2<=radius*radius;
}

// Far side of an AABB along the ray from a lamp through its centre. Static lamp
// ranking uses this for wide, thin world models: their enclosing sphere can put
// the probe outside the lamp radius even though light reaches past the fence.
float[3] BoundsFarPoint(const float[3] centre, const float[3] half, const float[3] eye)
{
	float[3] to=[centre[0]-eye[0], centre[1]-eye[1], centre[2]-eye[2]];
	float scale=float.max;
	foreach(c; 0..3)
		if (abs(to[c])>0.0001f) scale=min(scale, half[c]/abs(to[c]));
	if (scale==float.max) return centre;
	return [centre[0]+to[0]*scale, centre[1]+to[1]*scale, centre[2]+to[2]*scale];
}

// Fit a single static-lamp shadow view to a world model's actual bounds.
// A lamp beside a thin fence may lie inside its enclosing sphere while all
// fence vertices are still in front of the lamp and can cast a useful shadow.
bool BoundsShadowFrustum(const float[3] eye, float radius, const float[3] centre,
	const float[3] half, out float[16] matrix)
{
	float[3] forward;
	float distance2=0f, outside=0f;
	uint separating_axis;
	foreach(c; 0..3) {
		if (!isFinite(eye[c]) || !isFinite(centre[c]) || !isFinite(half[c]) || half[c]<0f) return false;
		forward[c]=centre[c]-eye[c]; distance2+=forward[c]*forward[c];
		const float gap=abs(forward[c])-half[c];
		if (gap>outside) { outside=gap; separating_axis=cast(uint)c; }
	}
	if (!isFinite(radius) || radius<=0f || outside<=0.001f) return false;
	const float distance=sqrt(distance2);
	forward[]/=distance;
	float min_depth=distance;
	foreach(c; 0..3) min_depth-=abs(forward[c])*half[c];
	if (min_depth<=0.001f) {
		// At an oblique corner the centre-facing view may put some corners
		// behind the eye. An axis separating the lamp and box keeps all in front.
		forward[]=0f;
		forward[separating_axis]=centre[separating_axis]>eye[separating_axis] ? 1f : -1f;
		min_depth=outside;
	}
	if (min_depth>=radius) return false;
	const float[3] hint=abs(forward[1])>0.95f ? [1f,0f,0f] : [0f,1f,0f];
	float[3] right=Cross(hint,forward);
	right[]/=sqrt(Dot(right,right));
	const float[3] up=Cross(forward,right);
	float slope=0f;
	foreach(corner; 0..8) {
		float[3] point;
		foreach(c; 0..3) point[c]=centre[c]+((corner & (1<<c)) ? half[c] : -half[c])-eye[c];
		const float depth=Dot(forward,point);
		if (depth<=0f) return false;
		slope=max(slope,max(abs(Dot(right,point)),abs(Dot(up,point)))/depth);
	}
	const float scale=1f/max(slope*1.05f,0.001f);
	const float near=min(1f,min_depth*0.9f), a=radius/(radius-near), b=-radius*near/(radius-near);
	foreach(c; 0..3) {
		matrix[c*4]=right[c]*scale; matrix[c*4+1]=up[c]*scale;
		matrix[c*4+2]=forward[c]*a; matrix[c*4+3]=forward[c];
	}
	matrix[12]=-Dot(right,eye)*scale; matrix[13]=-Dot(up,eye)*scale;
	matrix[14]=-Dot(forward,eye)*a+b; matrix[15]=-Dot(forward,eye);
	return true;
}

// Conservative per-face AABB clip test, performed on cached world bounds before issuing draws.
bool InFace(const float[16] m, const float[3] low, const float[3] high)
{
	float[3] centre, half;
	foreach(c; 0..3) { centre[c]=(low[c]+high[c])*0.5f; half[c]=(high[c]-low[c])*0.5f; }
	foreach(plane; 0..6) {
		float[4] eq;
		foreach(c; 0..4) {
			if (plane==4) eq[c]=m[c*4+2];
			else if (plane==5) eq[c]=m[c*4+3]-m[c*4+2];
			else eq[c]=m[c*4+3]+(plane%2==0 ? 1f : -1f)*m[c*4+plane/2];
		}
		float d=eq[3], support=0;
		foreach(c; 0..3) { d+=eq[c]*centre[c]; support+=abs(eq[c])*half[c]; }
		if (d < -support) return false;
	}
	return true;
}

private float Dot(const float[3] a, const float[3] b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
private float[3] Cross(const float[3] a, const float[3] b) {
	return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
}
