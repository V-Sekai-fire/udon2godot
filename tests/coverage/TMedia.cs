using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Audio, animation, particles, renderers, materials, lights, camera, line renderer, curves.
    public class TMedia : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public AudioSource audio;          // AudioStreamPlayer3D "Audio" with a generated stream
        public AudioClip clip;
        public Animator animator;          // AnimationPlayer "Anim" with animation "spin"
        public ParticleSystem particles;   // GPUParticles3D "Particles"
        public MeshRenderer meshRenderer;  // MeshInstance3D "Mesh" with a StandardMaterial3D
        public Light light;                // OmniLight3D "Light"
        public Camera cam;                 // Camera3D "Cam"
        public LineRenderer line;          // Node3D "Line"
        public AnimationCurve curve;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.01f; }

        public void RunTests()
        {
            // Audio
            Check(audio != null, "audio wired");
            audio.volume = 0.5f;
            Check(Near(audio.volume, 0.5f), "volume linear round trip: " + audio.volume);
            audio.pitch = 1.5f;
            Check(Near(audio.pitch, 1.5f), "pitch");
            audio.loop = true;
            Check(audio.loop, "loop on");
            audio.loop = false;
            audio.clip = clip;
            Check(audio.clip == clip, "clip assignment");
            Check(clip != null && clip.length > 0f, "AudioClip.length: " + (clip != null ? clip.length : -1f));
            audio.Play();
            Check(audio.isPlaying, "isPlaying after Play");
            audio.Pause();
            audio.UnPause();
            audio.Stop();
            Check(!audio.isPlaying, "isPlaying false after Stop");
            audio.PlayOneShot(clip, 0.8f);
            audio.PlayDelayed(0.1f);
            audio.mute = true;
            Check(audio.mute, "mute");
            audio.mute = false;
            audio.maxDistance = 25f;
            Check(Near(audio.maxDistance, 25f), "maxDistance");
            audio.time = 0f;
            Check(audio.time >= 0f, "time");
            audio.enabled = false;
            Check(!audio.enabled, "audio enabled false");
            audio.enabled = true;

            // Animator over an AnimationPlayer
            Check(animator != null, "animator wired");
            animator.SetFloat("Speed", 0.75f);
            animator.SetBool("Open", true);
            animator.SetInteger("Count", 3);
            Check(Near(animator.GetFloat("Speed"), 0.75f) && animator.GetBool("Open") && animator.GetInteger("Count") == 3, "animator parameters");
            animator.SetTrigger("Fire");
            animator.ResetTrigger("Fire");
            animator.Play("spin");
            AnimatorStateInfo info = animator.GetCurrentAnimatorStateInfo(0);
            Check(info.IsName("spin"), "GetCurrentAnimatorStateInfo.IsName");
            Check(info.length > 0f, "state length: " + info.length);
            animator.speed = 2f;
            Check(Near(animator.speed, 2f), "animator.speed");
            animator.speed = 1f;
            Check(Animator.StringToHash("spin") == Animator.StringToHash("spin"), "StringToHash stable");
            animator.enabled = true;
            Check(animator.enabled, "animator enabled");

            // Particles
            Check(particles != null, "particles wired");
            particles.Play();
            Check(particles.isPlaying && particles.isEmitting, "particles playing");
            particles.Stop();
            Check(!particles.isPlaying, "particles stopped");
            ParticleSystem.EmissionModule em = particles.emission;
            em.enabled = true;
            Check(em.enabled, "emission module enabled");
            em.rateOverTime = new ParticleSystem.MinMaxCurve(20f);
            Check(Near(em.rateOverTime.constant, 20f), "rateOverTime MinMaxCurve");
            ParticleSystem.MainModule main = particles.main;
            main.startLifetime = 2f;
            main.loop = false;
            Check(Near(main.startLifetime.constant, 2f) && !main.loop, "main module");
            main.startColor = Color.red;
            Check(Near(main.startColor.color.r, 1f), "startColor MinMaxGradient");
            particles.Emit(5);
            particles.Clear();

            // Renderer / Material
            Check(meshRenderer != null && meshRenderer.enabled, "renderer wired");
            meshRenderer.enabled = false;
            Check(!meshRenderer.enabled, "renderer disabled");
            meshRenderer.enabled = true;
            Material mat = meshRenderer.material;
            Check(mat != null, "renderer.material");
            mat.color = Color.green;
            Check(Near(mat.color.g, 1f) && Near(mat.color.r, 0f), "material.color");
            mat.SetColor("_Color", Color.blue);
            Check(Near(mat.GetColor("_Color").b, 1f), "SetColor/GetColor _Color");
            mat.SetFloat("_Glossiness", 0.25f);
            Check(Near(mat.GetFloat("_Glossiness"), 0.25f), "SetFloat/GetFloat mapped property");
            mat.SetFloat("_Custom", 3f);
            Check(Near(mat.GetFloat("_Custom"), 3f) && mat.HasProperty("_Custom"), "custom float property stored");
            mat.SetVector("_Vec", new Vector4(1, 2, 3, 4));
            Check(Near(mat.GetVector("_Vec").z, 3f), "SetVector/GetVector");
            Check(meshRenderer.sharedMaterial != null, "sharedMaterial");
            Check(meshRenderer.bounds.size.x > 0f, "renderer.bounds");
            MaterialPropertyBlock block = new MaterialPropertyBlock();
            block.SetColor("_Color", Color.yellow);
            block.SetFloat("_Alpha", 0.5f);
            meshRenderer.SetPropertyBlock(block);
            Check(Near(block.GetFloat("_Alpha"), 0.5f), "MaterialPropertyBlock get");
            mat.SetColor("_Color", Color.blue); // the property block above overrode the renderer's colour
            Material copy = new Material(mat);
            copy.color = Color.white;
            Check(Near(mat.color.b, 1f) && Near(copy.color.r, 1f), "new Material(Material) copies");

            // Light
            light.intensity = 2f;
            light.color = Color.cyan;
            light.range = 12f;
            Check(Near(light.intensity, 2f) && Near(light.color.g, 1f) && Near(light.range, 12f), "light props");
            light.enabled = false;
            Check(!light.enabled, "light disabled");
            light.enabled = true;

            // Camera
            Check(cam != null && Camera.main != null, "camera wired / Camera.main");
            cam.fieldOfView = 70f;
            Check(Near(cam.fieldOfView, 70f), "fieldOfView");
            cam.nearClipPlane = 0.1f;
            cam.farClipPlane = 500f;
            Check(Near(cam.nearClipPlane, 0.1f) && Near(cam.farClipPlane, 500f), "clip planes");
            Vector3 sp = cam.WorldToScreenPoint(cam.transform.position + cam.transform.forward * 10f);
            Check(sp.z > 9f && sp.z < 11f, "WorldToScreenPoint depth: " + sp.z);
            Ray r = cam.ScreenPointToRay(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
            Check(Vector3.Dot(r.direction, cam.transform.forward) > 0.9f, "ScreenPointToRay center points forward");
            Check(Screen.width > 0 && Screen.height > 0, "Screen size");

            // LineRenderer
            line.positionCount = 3;
            line.SetPosition(0, Vector3.zero);
            line.SetPosition(1, Vector3.up);
            line.SetPosition(2, Vector3.right);
            Check(line.positionCount == 3 && line.GetPosition(1) == Vector3.up, "LineRenderer positions");
            line.startWidth = 0.2f;
            line.startColor = Color.red;
            Check(Near(line.startWidth, 0.2f) && Near(line.startColor.r, 1f), "LineRenderer props");
            line.enabled = false;
            line.enabled = true;

            // AnimationCurve
            curve = AnimationCurve.Linear(0f, 0f, 1f, 10f);
            Check(Near(curve.Evaluate(0.5f), 5f), "AnimationCurve.Linear.Evaluate: " + curve.Evaluate(0.5f));
            AnimationCurve c2 = new AnimationCurve(new Keyframe(0, 1), new Keyframe(2, 3));
            Check(Near(c2.Evaluate(1f), 2f) && c2.length == 2, "AnimationCurve keys");

            // Time
            Check(Time.time >= 0f && Time.deltaTime >= 0f && Time.fixedDeltaTime > 0f, "Time statics");
            Check(Time.frameCount >= 0 && Time.realtimeSinceStartup > 0f, "frameCount/realtime");
            Check(Time.timeScale == 1f, "timeScale default");
            done = true;
        }
    }
}
