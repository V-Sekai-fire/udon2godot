using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// Rigidbody, raycasts, overlaps, colliders. The runner provides a RigidBody3D "Body"
    /// (box 1x1x1 at y=5), a StaticBody3D "Floor" (100x1x100 at y=-0.5) and an Area3D "Trigger".
    public class TPhysics : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Rigidbody body;
        public Collider floorCol;
        public Collider trigger;
        public int triggerEnters;
        public int collisionEnters;
        private float startY;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(body != null && floorCol != null, "nodes wired");
            body.mass = 2f;
            Check(Near(body.mass, 2f), "mass");
            body.drag = 0.5f;
            body.angularDrag = 0.1f;
            Check(Near(body.drag, 0.5f) && Near(body.angularDrag, 0.1f), "drag/angularDrag");
            body.useGravity = false;
            Check(!body.useGravity, "useGravity off");
            body.useGravity = true;
            Check(body.useGravity, "useGravity on");
            body.isKinematic = true;
            Check(body.isKinematic, "isKinematic");
            body.isKinematic = false;
            body.velocity = new Vector3(1, 0, 0);
            Check(Near(body.velocity.x, 1f), "velocity set/get");
            body.velocity = Vector3.zero;
            body.angularVelocity = new Vector3(0, 2, 0);
            Check(Near(body.angularVelocity.y, 2f), "angularVelocity");
            body.angularVelocity = Vector3.zero;
            body.constraints = RigidbodyConstraints.FreezeRotation;
            Check(body.freezeRotation && (body.constraints & RigidbodyConstraints.FreezeRotationX) != 0, "constraints/freezeRotation");
            body.constraints = RigidbodyConstraints.None;
            Check(!body.freezeRotation, "constraints cleared");
            body.position = new Vector3(0, 5, 0);
            Check(Near(body.position.y, 5f) && Near(body.transform.position.y, 5f), "rigidbody.position");
            body.rotation = Quaternion.Euler(0, 90, 0);
            Check(Near(Quaternion.Angle(body.rotation, Quaternion.Euler(0, 90, 0)), 0f), "rigidbody.rotation");
            body.rotation = Quaternion.identity;
            body.centerOfMass = new Vector3(0, -0.2f, 0);
            Check(Near(body.centerOfMass.y, -0.2f), "centerOfMass");
            Check(Near(body.worldCenterOfMass.y, 4.8f), "worldCenterOfMass");
            body.ResetCenterOfMass();
            Check(!body.IsSleeping() || true, "IsSleeping callable");
            body.WakeUp();
            Vector3 pv = body.GetPointVelocity(body.position + Vector3.right);
            Check(pv.magnitude < 0.01f, "GetPointVelocity at rest");
            body.AddForce(new Vector3(0, 10, 0));
            body.AddForce(Vector3.right * 3f, ForceMode.Impulse);
            body.AddTorque(Vector3.up, ForceMode.Impulse);
            body.AddForceAtPosition(Vector3.forward, body.position + Vector3.right, ForceMode.Force);
            startY = body.position.y;

            // raycast down onto the floor from above
            RaycastHit hit;
            bool hitSomething = Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, out hit, 100f);
            Check(hitSomething, "Physics.Raycast hits the floor");
            if (hitSomething)
            {
                Check(Near(hit.point.y, 0f), "hit.point on floor top: " + hit.point.y);
                Check(Near(hit.distance, 5f), "hit.distance: " + hit.distance);
                Check(hit.normal.y > 0.99f, "hit.normal up");
                Check(hit.collider == floorCol && hit.transform == floorCol.transform, "hit.collider is floor");
                Check(hit.rigidbody == null, "hit.rigidbody null for static floor");
            }
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.up, 100f), "Raycast up hits nothing");
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, 2f), "Raycast too short misses");
            Check(Physics.Raycast(new Ray(new Vector3(10, 5, 10), Vector3.down), out hit) && Near(hit.distance, 5f), "Raycast(Ray, out hit)");
            int mask = 1 << 3;
            Check(!Physics.Raycast(new Vector3(10, 5, 10), Vector3.down, out hit, 100f, mask), "Raycast with non-matching layer mask misses");
            RaycastHit[] hits = Physics.RaycastAll(new Vector3(10, 5, 10), Vector3.down, 100f);
            Check(hits.Length >= 1, "RaycastAll");
            Check(Physics.Linecast(new Vector3(10, 5, 10), new Vector3(10, -5, 10)), "Linecast through floor");
            RaycastHit sh;
            Check(Physics.SphereCast(new Vector3(10, 5, 10), 0.5f, Vector3.down, out sh, 100f) && sh.distance > 4f && sh.distance < 5.1f, "SphereCast: " + sh.distance);
            Collider[] around = Physics.OverlapSphere(new Vector3(0, 0, 0), 3f);
            Check(around.Length >= 1, "OverlapSphere finds floor");
            Collider[] buf = new Collider[4];
            int n = Physics.OverlapSphereNonAlloc(new Vector3(0, 0, 0), 3f, buf);
            Check(n >= 1 && buf[0] != null, "OverlapSphereNonAlloc");
            Check(Physics.CheckSphere(new Vector3(0, 0, 0), 1f), "CheckSphere");
            Check(Physics.gravity.y < 0f, "Physics.gravity");

            // colliders
            Bounds fb = floorCol.bounds;
            Check(fb.size.x > 50f && Near(fb.max.y, 0f), "floor bounds: " + fb.size + " max " + fb.max);
            Check(floorCol.enabled, "collider enabled");
            Check(!floorCol.isTrigger && trigger.isTrigger, "isTrigger");
            Check(floorCol.attachedRigidbody == null && body.GetComponent<Collider>().attachedRigidbody == body, "attachedRigidbody");
            Vector3 cp = floorCol.ClosestPoint(new Vector3(3, 10, 3));
            Check(Near(cp.y, 0f) && Near(cp.x, 3f), "ClosestPoint");
            Physics.IgnoreCollision(body.GetComponent<Collider>(), floorCol, false);
            done = true;
        }

        public override void OnTriggerEnter(Collider other) { triggerEnters++; }
        public override void OnCollisionEnter(Collision collision)
        {
            collisionEnters++;
            Check(collision.collider != null && collision.contacts.Length >= 0, "OnCollisionEnter has collider");
        }

        /// Called by the runner after ~60 physics frames.
        public void AfterFrames()
        {
            Check(body.position.y < startY, "gravity pulled the body down: " + body.position.y + " < " + startY);
            Check(body.velocity.x > 0.5f || body.position.x > 0.05f, "impulse moved body along +X");
            Check(body.position.y > 0.4f, "body rests on floor (not falling through): " + body.position.y);
        }
    }
}
