using UdonSharp;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;
using VRC.Udon.Common.Interfaces;

namespace Sample
{
    public enum Phase { Idle, Running = 5, Done }

    [UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
    public class Counter : UdonSharpBehaviour
    {
        [Tooltip("How fast the counter spins")]
        public float speed = 2f;
        public GameObject[] toggleObjects;
        public Transform target;
        public Counter other;
        [UdonSynced] private int count;
        [UdonSynced, FieldChangeCallback(nameof(Phase))] private Phase _phase = Phase.Idle;
        private Vector3[] positions = new Vector3[4];
        private string label = "c";
        private const int MAX = 10;
        private const float HALF = MAX / 2f;
        private bool[] flags;
        private float[,] grid;
        private VRCPlayerApi localPlayer;

        public Phase Phase
        {
            get => _phase;
            set
            {
                _phase = value;
                if (value == Phase.Done) Debug.Log("done!");
            }
        }

        public int Total { get; set; }

        void Start()
        {
            localPlayer = Networking.LocalPlayer;
            flags = new bool[MAX];
            grid = new float[2, 3];
            grid[1, 2] = 4.5f;
            for (int i = 0; i < positions.Length; i++)
            {
                positions[i] = new Vector3(i, 0f, i * 2f) + Vector3.up * 0.5f;
            }
            if (target != null && target)
            {
                target.position = transform.position + transform.forward * speed;
            }
            label += count.ToString() + " " + speed.ToString("F2") + $" phase={_phase}";
        }

        public override void Interact()
        {
            if (!Networking.IsOwner(gameObject)) Networking.SetOwner(localPlayer, gameObject);
            count++;
            count = Mathf.Clamp(count, 0, MAX);
            Phase = count >= MAX ? Phase.Done : Phase.Running;
            RequestSerialization();
            SendCustomNetworkEvent(NetworkEventTarget.All, nameof(OnBump), count);
            SendCustomEventDelayedSeconds(nameof(Reset), 3f);
        }

        [NetworkCallable]
        public void OnBump(int newCount)
        {
            Total += newCount;
            foreach (GameObject go in toggleObjects)
            {
                if (go) go.SetActive(!go.activeSelf);
            }
        }

        public void Reset()
        {
            count = 0;
            Phase = Phase.Idle;
        }

        public override void OnDeserialization()
        {
            Total = count * 2;
        }

        private void Update()
        {
            float dt = Time.deltaTime;
            transform.Rotate(Vector3.up, speed * dt * 90f);
            if (Input.GetKeyDown(KeyCode.Space)) Interact();
            int j = 0;
            while (j < 3)
            {
                j++;
                if (j == 2) continue;
            }
            do { j--; } while (j > 0);
            switch (_phase)
            {
                case Phase.Idle:
                case Phase.Running:
                    j = 1;
                    break;
                default:
                    j = 2;
                    break;
            }
            switch (label)
            {
                case "a": j = 3; break;
                case "b": if (j > 1) break; j = 4; break;
            }
            float m = Mathf.Sqrt(j) % 2f + (float)j / 2;
            int k = (int)m + j % 2;
            Vector3 dir = (target.position - transform.position).normalized;
            float d = Vector3.Distance(target.position, transform.position);
            Quaternion q = Quaternion.Euler(0f, 90f, 0f) * Quaternion.identity;
            RaycastHit hit;
            if (Physics.Raycast(transform.position, dir, out hit, 10f))
            {
                Debug.Log("hit " + hit.collider.name + " at " + hit.point);
            }
            var rb = GetComponent<Rigidbody>();
            if (rb != null) rb.AddForce(dir * 2f, ForceMode.Impulse);
            var cnt = other.GetComponent<Counter>();
            if (cnt) cnt.SendCustomEvent("Reset");
            VRCPlayerApi p = VRCPlayerApi.GetPlayerById(1);
            if (Utilities.IsValid(p) && p.IsUserInVR())
            {
                Vector3 head = p.GetTrackingData(VRCPlayerApi.TrackingDataType.Head).position;
                p.TeleportTo(head, Quaternion.identity);
            }
            string s = string.Format("{0} of {1}", count, MAX);
            bool any = flags[0] || flags[1] && !flags[2];
            long big = 1L << 40;
            uint u = (uint)k;
            float t = Mathf.Lerp(0f, HALF, 0.5f);
            positions[0].x += t;
            grid[0, 1] = t;
            k += k++ + ++k;
        }

        public override void OnPlayerJoined(VRCPlayerApi player)
        {
            Debug.Log(player.displayName + " joined; count=" + VRCPlayerApi.GetPlayerCount());
        }

        private bool TryGet(int idx, out float value)
        {
            if (idx < 0 || idx >= positions.Length) { value = 0f; return false; }
            value = positions[idx].y;
            return true;
        }

        public float Sum()
        {
            float total = 0f;
            float v;
            for (int i = 0; i < MAX; i++)
            {
                if (TryGet(i, out v)) total += v;
            }
            return total;
        }
    }
}
