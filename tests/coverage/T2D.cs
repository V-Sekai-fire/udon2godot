using UdonSharp;
using UnityEngine;

namespace Coverage
{
    /// 2D physics over Godot 2D nodes: RigidBody2D "Body2D" (circle r=0.5 at y=5 Unity units),
    /// StaticBody2D "Floor2D" (200x1 box at y=-0.5). Unity 2D is Y-up; the runtime flips Y.
    public class T2D : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;

        public Rigidbody2D body;
        public Collider2D floorCol;
        private float startY;

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool Near(float a, float b) { return Mathf.Abs(a - b) < 0.05f; }

        public void RunTests()
        {
            Check(body != null && floorCol != null, "2D nodes wired");
            body.mass = 3f;
            body.gravityScale = 1f;
            Check(Near(body.mass, 3f) && Near(body.gravityScale, 1f), "mass/gravityScale");
            body.position = new Vector2(0, 5);
            Check(Near(body.position.y, 5f), "position (Y-up) round trip: " + body.position);
            body.velocity = new Vector2(1, 2);
            Check(Near(body.velocity.x, 1f) && Near(body.velocity.y, 2f), "velocity round trip (Y flipped internally)");
            body.velocity = Vector2.zero;
            body.rotation = 45f;
            Check(Near(body.rotation, 45f), "rotation degrees round trip: " + body.rotation);
            body.rotation = 0f;
            body.angularVelocity = 90f;
            Check(Near(body.angularVelocity, 90f), "angularVelocity");
            body.angularVelocity = 0f;
            body.freezeRotation = true;
            Check(body.freezeRotation && (body.constraints & RigidbodyConstraints2D.FreezeRotation) != 0, "freezeRotation/constraints");
            body.freezeRotation = false;
            body.isKinematic = true;
            Check(body.isKinematic && body.bodyType == RigidbodyType2D.Kinematic, "isKinematic/bodyType");
            body.bodyType = RigidbodyType2D.Dynamic;
            Check(!body.isKinematic, "bodyType Dynamic");
            body.drag = 0.2f;
            body.angularDrag = 0.1f;
            Check(Near(body.drag, 0.2f) && Near(body.angularDrag, 0.1f), "2D drag");
            body.AddForce(new Vector2(0, 5));
            body.AddForce(new Vector2(3, 0), ForceMode2D.Impulse);
            body.AddTorque(1f);
            Vector2 wp = body.GetRelativePoint(new Vector2(1, 0));
            Check(Near(wp.x, 1f) && Near(wp.y, 5f), "GetRelativePoint: " + wp);
            startY = body.position.y;

            RaycastHit2D hit = Physics2D.Raycast(new Vector2(20, 5), Vector2.down);
            Check(hit, "Physics2D.Raycast hits floor (implicit bool)");
            Check(hit.collider == floorCol, "hit.collider is floor");
            Check(Near(hit.point.y, 0f) && Near(hit.distance, 5f), "hit point/distance: " + hit.point + " " + hit.distance);
            Check(hit.normal.y > 0.9f, "hit normal up (Unity Y-up)");
            RaycastHit2D miss = Physics2D.Raycast(new Vector2(20, 5), Vector2.up, 100f);
            Check(!miss && miss.collider == null, "Raycast up misses");
            RaycastHit2D[] all = Physics2D.RaycastAll(new Vector2(20, 5), Vector2.down, 100f);
            Check(all.Length >= 1, "RaycastAll");
            Collider2D[] found = Physics2D.OverlapCircleAll(new Vector2(20, 0), 2f);
            Check(found.Length >= 1, "OverlapCircleAll finds floor");
            Collider2D one = Physics2D.OverlapPoint(new Vector2(20, -0.5f));
            Check(one == floorCol, "OverlapPoint inside floor");
            Check(Physics2D.OverlapPoint(new Vector2(20, 50)) == null, "OverlapPoint empty");
            RaycastHit2D circle = Physics2D.CircleCast(new Vector2(20, 5), 0.5f, Vector2.down, 100f);
            Check(circle && circle.distance > 4f && circle.distance < 5.1f, "CircleCast: " + circle.distance);
            Check(Physics2D.gravity.y < 0f, "Physics2D.gravity points down (Unity axes)");
            Bounds fb = floorCol.bounds;
            Check(fb.size.x > 100f, "Collider2D.bounds: " + fb.size);
            Check(!floorCol.isTrigger && floorCol.enabled && floorCol.attachedRigidbody == null, "Collider2D props");
            Check(body.GetComponent<Collider2D>().attachedRigidbody == body, "attachedRigidbody 2D");
            Physics2D.IgnoreCollision(body.GetComponent<Collider2D>(), floorCol, false);
            done = true;
        }

        public void AfterFrames()
        {
            Check(body.position.y < startY, "2D gravity moved the body down: " + body.position.y);
            Check(body.position.x > 0.05f, "2D impulse moved body along +X: " + body.position.x);
            Check(body.position.y > 0.2f, "2D body rests on floor: " + body.position.y);
        }
    }
}
