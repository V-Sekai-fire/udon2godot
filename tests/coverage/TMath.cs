using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Math and numeric semantics: Mathf, Vector3/2, Quaternion, Color, Matrix4x4, casts, operators.
    public class TMath : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.001f; }
        private bool NearV(Vector3 a, Vector3 b) { return (a - b).magnitude < 0.001f; }

        public void RunTests()
        {
            // Integer semantics
            int i7 = 7, i2 = 2;
            Check(i7 / i2 == 3, "int division truncates");
            Check(-7 / 2 == -3, "negative int division truncates toward zero");
            Check(-7 % 3 == -1, "int remainder keeps dividend sign");
            Check(Near(7 % 2.5f, 2f), "float remainder");
            Check((int)2.9f == 2 && (int)-2.9f == -2, "float→int cast truncates");
            Check((byte)300 == 44, "byte cast wraps");
            Check((short)40000 == -25536, "short cast wraps");
            Check((int)3000000000L == -1294967296, "int cast wraps");
            Check(unchecked((uint)-1) == 4294967295u, "uint cast of -1");
            Check(1 << 10 == 1024 && (1024 >> 3) == 128, "shifts");
            Check((5 & 3) == 1 && (5 | 3) == 7 && (5 ^ 3) == 6 && (~5) == -6, "bit ops");
            Check((int)'A' == 65 && (char)66 == 'B', "char/int conversions");
            Check('a' + 1 == 98, "char arithmetic promotes to int");
            float f = 3;
            Check(Near(f / 2, 1.5f), "int→float promotion in division");
            Check(Near(7f / 2, 3.5f), "float division");
            Check(Near(1e-3f, 0.001f), "exponent literal");
            Check(0x1F == 31, "hex literal");
            long big = 1L << 40;
            Check(big == 1099511627776L, "long shift");
            int x = 5;
            x += 3; x *= 2; x -= 1; x /= 3; x %= 4;
            Check(x == 1, "compound assignment chain: " + x);
            int pre = 1;
            int post = pre++ + ++pre;
            Check(post == 4 && pre == 3, "pre/post increment in expression");
            bool b = true;
            b &= false;
            b |= true;
            b ^= true;
            Check(b == false, "bool compound ops");

            // Mathf
            Check(Near(Mathf.Clamp(5f, 0f, 1f), 1f) && Mathf.Clamp(-3, 0, 10) == 0, "Mathf.Clamp");
            Check(Near(Mathf.Lerp(0f, 10f, 0.25f), 2.5f) && Near(Mathf.Lerp(0f, 10f, 2f), 10f), "Mathf.Lerp clamps");
            Check(Near(Mathf.LerpUnclamped(0f, 10f, 2f), 20f), "LerpUnclamped");
            Check(Near(Mathf.InverseLerp(0f, 10f, 2.5f), 0.25f), "InverseLerp");
            Check(Near(Mathf.Sqrt(16f), 4f) && Near(Mathf.Pow(2f, 10f), 1024f), "Sqrt/Pow");
            Check(Near(Mathf.Abs(-1.5f), 1.5f) && Mathf.Abs(-3) == 3, "Abs");
            Check(Near(Mathf.Min(1f, 2f), 1f) && Mathf.Max(1, 2) == 2, "Min/Max");
            Check(Near(Mathf.Floor(2.7f), 2f) && Near(Mathf.Ceil(2.1f), 3f) && Mathf.FloorToInt(-2.5f) == -3, "Floor/Ceil");
            Check(Mathf.RoundToInt(2.5f) == 2 && Mathf.RoundToInt(3.5f) == 4, "Round to even");
            Check(Near(Mathf.Sign(0f), 1f) && Near(Mathf.Sign(-2f), -1f), "Sign(0) is 1");
            Check(Near(Mathf.Repeat(370f, 360f), 10f) && Near(Mathf.Repeat(-10f, 360f), 350f), "Repeat");
            Check(Near(Mathf.PingPong(3f, 2f), 1f), "PingPong");
            Check(Near(Mathf.MoveTowards(0f, 10f, 3f), 3f), "MoveTowards");
            Check(Near(Mathf.DeltaAngle(350f, 10f), 20f), "DeltaAngle");
            Check(Near(Mathf.Atan2(1f, 1f) * Mathf.Rad2Deg, 45f), "Atan2 + Rad2Deg");
            Check(Near(Mathf.Sin(Mathf.PI / 2f), 1f) && Near(Mathf.Cos(0f), 1f), "Sin/Cos");
            Check(Near(90f * Mathf.Deg2Rad, Mathf.PI / 2f), "Deg2Rad");
            Check(Mathf.Approximately(0.1f + 0.2f, 0.3f), "Approximately");
            Check(Near(Mathf.Clamp01(1.5f), 1f), "Clamp01");
            Check(Mathf.Infinity > 1e30f && float.IsInfinity(Mathf.Infinity), "Infinity");
            Check(float.IsNaN(float.NaN) && !float.IsNaN(1f), "NaN");
            Check(Near(Mathf.SmoothStep(0f, 10f, 0.5f), 5f), "SmoothStep midpoint");
            Check(Mathf.IsPowerOfTwo(64) && Mathf.NextPowerOfTwo(33) == 64, "power of two");
            float perlin = Mathf.PerlinNoise(0.3f, 0.7f);
            Check(perlin >= 0f && perlin <= 1f, "PerlinNoise range");
            float vel = 0f;
            float sd = Mathf.SmoothDamp(0f, 10f, ref vel, 0.5f, Mathf.Infinity, 0.1f);
            Check(sd > 0f && sd < 10f && vel > 0f, "SmoothDamp progresses and updates ref velocity");
            Check(Mathf.Max(1, 5, 3) == 5 && Near(Mathf.Min(1f, 0.5f, 3f), 0.5f), "params Min/Max");

            // Vector3
            Vector3 v = new Vector3(3, 4, 0);
            Check(Near(v.magnitude, 5f) && Near(v.sqrMagnitude, 25f), "magnitude");
            Check(NearV(v.normalized, new Vector3(0.6f, 0.8f, 0)), "normalized");
            Check(Near(Vector3.Dot(Vector3.up, Vector3.up), 1f) && Near(Vector3.Dot(Vector3.up, Vector3.right), 0f), "Dot");
            Check(NearV(Vector3.Cross(Vector3.right, Vector3.up), Vector3.forward), "Cross (Unity handedness)");
            Check(Near(Vector3.Distance(Vector3.zero, v), 5f), "Distance");
            Check(NearV(Vector3.Lerp(Vector3.zero, Vector3.one, 0.5f), new Vector3(0.5f, 0.5f, 0.5f)), "Vector3.Lerp");
            Check(NearV(Vector3.Lerp(Vector3.zero, Vector3.one, 3f), Vector3.one), "Vector3.Lerp clamps");
            Check(NearV(Vector3.Scale(new Vector3(1, 2, 3), new Vector3(2, 2, 2)), new Vector3(2, 4, 6)), "Scale");
            Check(Near(Vector3.Angle(Vector3.right, Vector3.up), 90f), "Angle");
            Check(Near(Vector3.SignedAngle(Vector3.right, Vector3.up, Vector3.forward), 90f), "SignedAngle");
            Check(NearV(Vector3.ProjectOnPlane(new Vector3(1, 1, 0), Vector3.up), Vector3.right), "ProjectOnPlane");
            Check(NearV(Vector3.Reflect(new Vector3(1, -1, 0), Vector3.up), new Vector3(1, 1, 0)), "Reflect");
            Check(NearV(Vector3.ClampMagnitude(new Vector3(10, 0, 0), 2f), new Vector3(2, 0, 0)), "ClampMagnitude");
            Check(NearV(Vector3.MoveTowards(Vector3.zero, new Vector3(10, 0, 0), 3f), new Vector3(3, 0, 0)), "Vector3.MoveTowards");
            Check(NearV(v * 2f, new Vector3(6, 8, 0)) && NearV(2f * v, new Vector3(6, 8, 0)) && NearV(v / 2f, new Vector3(1.5f, 2, 0)), "scalar ops");
            Check(NearV(-v, new Vector3(-3, -4, 0)) && NearV(v + Vector3.one - Vector3.one, v), "vector add/sub/neg");
            Check(v == new Vector3(3, 4, 0) && v != Vector3.zero, "vector equality");
            v.x = 1f;
            v.Normalize();
            Check(Near(v.magnitude, 1f), "in-place Normalize");
            Vector3 vs = new Vector3(1, 2, 3);
            vs.Set(4, 5, 6);
            Check(NearV(vs, new Vector3(4, 5, 6)), "Set");
            Check(Near(vs[1], 5f), "indexer");
            Vector3 fwd = Vector3.forward;
            Check(Near(fwd.z, 1f) && Near(Vector3.back.z, -1f), "Vector3.forward is +Z (Unity axes)");
            Check(Near(Vector3.up.y, 1f) && Near(Vector3.down.y, -1f) && Near(Vector3.left.x, -1f), "axis constants");

            done = true;
        }
    }
}
