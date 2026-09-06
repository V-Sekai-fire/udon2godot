using System;
using UdonSharp;
using UnityEngine;
using VRC.SDK3.Data;

namespace Coverage
{
    public enum Suit { Hearts, Spades = 5, Clubs }

    [Flags]
    public enum Perm { None = 0, Read = 1, Write = 2, Exec = 4 }

    /// Arrays, control flow, out/ref, enums, switch, VRC data containers and JSON.
    public class TArrays : UdonSharpBehaviour
    {
        public string[] failures = new string[128];
        public int failCount;
        public int total;
        public bool done;
        private const int SIZE = 4;
        private int[] field = new int[] { 3, 1, 2 };
        private Vector3[] points = new Vector3[SIZE];

        private void Check(bool ok, string what)
        {
            total++;
            if (!ok) { failures[failCount] = what; failCount++; }
        }

        private bool TryDivide(int a, int b, out int result)
        {
            if (b == 0) { result = 0; return false; }
            result = a / b;
            return true;
        }

        private void Swap(ref int a, ref int b) { int t = a; a = b; b = t; }

        private int Sum(params int[] values)
        {
            int s = 0;
            foreach (int v in values) s += v;
            return s;
        }

        private int Fib(int n) { return n < 2 ? n : Fib(n - 1) + Fib(n - 2); }

        private string Classify(Suit s)
        {
            switch (s)
            {
                case Suit.Hearts: return "red";
                case Suit.Spades:
                case Suit.Clubs: return "black";
                default: return "?";
            }
        }

        public void RunTests()
        {
            // arrays
            Check(field.Length == 3 && field[0] == 3, "field array initializer");
            Check(points.Length == SIZE && points[2] == Vector3.zero, "new Vector3[SIZE] default-initialized");
            bool[] flags = new bool[3];
            Check(!flags[1], "new bool[] defaults false");
            string[] names = new string[2];
            names[0] = "a";
            Check(names[0] == "a" && (names[1] == null || names[1] == ""), "string array default");
            int[] copy = (int[])field.Clone();
            copy[0] = 99;
            Check(field[0] == 3 && copy[0] == 99, "Clone is a copy");
            int[] dst = new int[5];
            Array.Copy(field, dst, 3);
            Check(dst[0] == 3 && dst[2] == 2 && dst[3] == 0, "Array.Copy");
            Array.Copy(field, 1, dst, 3, 2);
            Check(dst[3] == 1 && dst[4] == 2, "Array.Copy with offsets");
            Check(Array.IndexOf(field, 2) == 2 && Array.IndexOf(field, 7) == -1, "Array.IndexOf");
            int[] sorted = (int[])field.Clone();
            Array.Sort(sorted);
            Check(sorted[0] == 1 && sorted[2] == 3, "Array.Sort");
            Array.Reverse(sorted);
            Check(sorted[0] == 3, "Array.Reverse");
            float[,] grid = new float[2, 3];
            grid[1, 2] = 4.5f;
            Check(grid[1, 2] == 4.5f && grid.GetLength(0) == 2 && grid.GetLength(1) == 3, "2D array");
            int[][] jagged = new int[2][];
            jagged[0] = new int[] { 1, 2 };
            jagged[1] = new int[3];
            Check(jagged[0][1] == 2 && jagged[1].Length == 3, "jagged array");
            int[] big = new int[100];
            for (int i = 0; i < big.Length; i++) big[i] = i * i;
            Check(big[99] == 9801, "for loop over Length");
            int acc = 0;
            foreach (int v in field) acc += v;
            Check(acc == 6, "foreach sum");
            foreach (Vector3 p in points) acc += (int)p.x;
            Check(acc == 6, "foreach over struct array");
            int k = 0, count = 0;
            while (k < 10) { k++; if (k % 2 == 0) continue; if (k > 7) break; count++; }
            Check(count == 4, "while/continue/break: " + count);
            int dw = 0;
            do { dw++; } while (dw < 3);
            Check(dw == 3, "do/while");
            int dw2 = 10;
            do { dw2++; } while (dw2 < 3);
            Check(dw2 == 11, "do/while runs body once");
            for (int a = 0, b = 10; a < b; a += 3, b -= 3) count++;
            Check(count == 6, "for with two variables: " + count);
            for (int i = 5; i >= 0; i -= 2) count += i;
            Check(count == 15, "for descending: " + count);
            int q;
            Check(TryDivide(10, 3, out q) && q == 3, "out parameter");
            Check(!TryDivide(1, 0, out q) && q == 0, "out parameter on failure path");
            int sa = 1, sb = 2;
            Swap(ref sa, ref sb);
            Check(sa == 2 && sb == 1, "ref parameters");
            Check(Sum() == 0 && Sum(1) == 1 && Sum(1, 2, 3) == 6 && Sum(field) == 6, "params");
            Check(Fib(10) == 55, "recursion");
            int tern = count > 100 ? 1 : count > 10 ? 2 : 3;
            Check(tern == 2, "nested ternary");
            string maybe = null;
            string coalesced = maybe ?? "default";
            Check(coalesced == "default", "null coalescing");
            object o = null;
            Check(o == null && !(o != null), "object null checks");
            // switch on int and string
            int sw = 2;
            string swr = "";
            switch (sw)
            {
                case 1: swr = "one"; break;
                case 2:
                    swr = "two";
                    if (sw == 2) break;
                    swr = "unreachable";
                    break;
                default: swr = "many"; break;
            }
            Check(swr == "two", "switch with early break: " + swr);
            switch ("b")
            {
                case "a": swr = "A"; break;
                case "b": swr = "B"; break;
            }
            Check(swr == "B", "switch on string");

            // enums
            Suit s = Suit.Spades;
            Check((int)s == 5 && (int)Suit.Clubs == 6 && (Suit)0 == Suit.Hearts, "enum values");
            Check(Classify(Suit.Clubs) == "black" && Classify(Suit.Hearts) == "red" && Classify((Suit)9) == "?", "switch on enum");
            Perm p = Perm.Read | Perm.Exec;
            Check((p & Perm.Exec) == Perm.Exec && (p & Perm.Write) == 0, "flags enum bit ops");
            Check(p.HasFlag(Perm.Read) && !p.HasFlag(Perm.Write), "Enum.HasFlag");
            p |= Perm.Write;
            p &= ~Perm.Read;
            Check((int)p == 6, "enum compound ops: " + (int)p);

            // checked/unchecked and overflow at casts
            int maxi = int.MaxValue;
            long widened = maxi + 1L;
            Check(widened == 2147483648L, "long widening avoids overflow");
            Check(unchecked((int)widened) == int.MinValue, "unchecked narrowing wraps");
            uint u = uint.MaxValue;
            Check(u == 4294967295u && (int)u == -1, "uint max and cast");
            byte by = 250;
            by += 10;
            Check(by == 4 || by == 260, "byte arithmetic (C# wraps: 4): " + by);

            // DataList / DataDictionary / DataToken / VRCJson
            DataList list = new DataList();
            list.Add(1);
            list.Add("two");
            list.Add(3.5f);
            list.Add(true);
            Check(list.Count == 4 && list[1].String == "two" && list[0].Int == 1 && list[2].Float == 3.5f && list[3].Boolean, "DataList add/index");
            DataToken tok;
            Check(list.TryGetValue(1, out tok) && tok.TokenType == TokenType.String, "DataList.TryGetValue + TokenType");
            Check(!list.TryGetValue(9, out tok), "DataList.TryGetValue out of range");
            list.Insert(0, "first");
            list.RemoveAt(1);
            Check(list[0].String == "first" && list.Count == 4 && list.IndexOf("two") == 1 && list.Contains(true), "DataList insert/remove/find");
            DataDictionary dict = new DataDictionary();
            dict["name"] = "udon";
            dict.Add("n", 7);
            dict["nested"] = list;
            Check(dict.Count == 3 && dict.ContainsKey("n") && dict["n"].Int == 7, "DataDictionary basics");
            DataToken got;
            Check(dict.TryGetValue("name", out got) && got.String == "udon", "DataDictionary.TryGetValue");
            Check(dict.TryGetValue("nested", TokenType.DataList, out got) && got.DataList.Count == 4, "TryGetValue with type");
            Check(!dict.TryGetValue("nope", out got), "TryGetValue missing");
            dict.Remove("n");
            Check(dict.Count == 2 && dict.GetKeys().Count == 2, "DataDictionary.Remove/GetKeys");
            DataToken json;
            if (VRCJson.TrySerializeToJson(dict, JsonExportType.Minify, out json))
            {
                Check(json.String.Contains("\"name\":\"udon\"") || json.String.Contains("\"name\": \"udon\""), "TrySerializeToJson: " + json.String);
                DataToken back;
                Check(VRCJson.TryDeserializeFromJson(json.String, out back) && back.TokenType == TokenType.DataDictionary, "TryDeserializeFromJson");
                Check(back.DataDictionary["name"].String == "udon" && back.DataDictionary["nested"].DataList[1].String == "two", "JSON round trip content");
            }
            else Check(false, "TrySerializeToJson failed");
            DataToken bad;
            Check(!VRCJson.TryDeserializeFromJson("{not json", out bad), "TryDeserializeFromJson rejects invalid");
            DataToken num = 42;
            Check(num.TokenType == TokenType.Int && num.Number == 42 && num.IsNumber, "DataToken implicit int");
            DataToken str = "s";
            Check(str.TokenType == TokenType.String && !str.IsNull, "DataToken implicit string");
            DataToken nul = DataToken.Null;
            Check(nul.IsNull && nul.TokenType == TokenType.Null, "DataToken.Null");
            list.Sort();
            Check(list.Count == 4, "DataList.Sort mixed types does not crash");
            DataList cloned = list.DeepClone();
            cloned.Clear();
            Check(cloned.Count == 0 && list.Count == 4, "DeepClone independent");
            done = true;
        }
        }
}
