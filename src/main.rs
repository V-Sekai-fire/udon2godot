//! udon2godot command-line driver.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use udon2godot::api::Catalog;
use udon2godot::ast::CompilationUnit;
use udon2godot::diag::{Diagnostics, Severity};
use udon2godot::externs::ExternTable;
use udon2godot::lower::{lower_class, LowerOptions};
use udon2godot::parser::parse_source;
use udon2godot::program::Program;

const USAGE: &str = "udon2godot — convert UdonSharp (VRChat Udon C#) scripts to SafeGDScript (.sgd)

USAGE:
    udon2godot [OPTIONS] <FILE.cs | DIR>...

OPTIONS:
    -o, --out <DIR>          Output directory for .sgd files (default: ./out)
    --base-script <PATH>     Script the generated behaviours extend
                             (default: res://addons/udon_runtime/udon_behaviour.gd)
    --res-prefix <PATH>      Resource path of the output directory inside the Godot project,
                             used for `extends` between converted scripts (default: res://)
    --class-name             Emit `class_name` (not allowed in a restricted sandbox)
    --report                 Print a per-class API usage report
    --report-json <FILE>     Write the usage report as JSON
    --check                  Parse and analyze only; write nothing
    --externs <FILE>         Use a custom KnownExterns list (one signature per line)
    --catalog-coverage       Print which Udon externs of catalog types are not mapped
    --coverage-missing <FILE> Write every unmapped extern (all types) as `Type<TAB>member` lines
    -q, --quiet              Only print errors
    -h, --help               Show this help
";

struct Args {
    inputs: Vec<PathBuf>,
    out: PathBuf,
    base_script: String,
    res_prefix: String,
    class_name: bool,
    report: bool,
    report_json: Option<PathBuf>,
    check: bool,
    externs: Option<PathBuf>,
    coverage: bool,
    coverage_missing: Option<PathBuf>,
    quiet: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut a = Args {
        inputs: vec![],
        out: PathBuf::from("out"),
        base_script: "res://addons/udon_runtime/udon_behaviour.gd".into(),
        res_prefix: "res://".into(),
        class_name: false,
        report: false,
        report_json: None,
        check: false,
        externs: None,
        coverage: false,
        coverage_missing: None,
        quiet: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "-h" | "--help" => {
                print!("{}", USAGE);
                std::process::exit(0);
            }
            "-o" | "--out" => a.out = PathBuf::from(it.next().ok_or("--out needs a value")?),
            "--base-script" => a.base_script = it.next().ok_or("--base-script needs a value")?,
            "--res-prefix" => {
                let mut v = it.next().ok_or("--res-prefix needs a value")?;
                if !v.ends_with('/') {
                    v.push('/');
                }
                a.res_prefix = v;
            }
            "--class-name" => a.class_name = true,
            "--report" => a.report = true,
            "--report-json" => a.report_json = Some(PathBuf::from(it.next().ok_or("--report-json needs a value")?)),
            "--check" => a.check = true,
            "--externs" => a.externs = Some(PathBuf::from(it.next().ok_or("--externs needs a value")?)),
            "--catalog-coverage" => a.coverage = true,
            "--coverage-missing" => a.coverage_missing = Some(PathBuf::from(it.next().ok_or("--coverage-missing needs a value")?)),
            "-q" | "--quiet" => a.quiet = true,
            s if s.starts_with('-') => return Err(format!("unknown option `{}`", s)),
            s => a.inputs.push(PathBuf::from(s)),
        }
    }
    if a.inputs.is_empty() && !a.coverage && a.coverage_missing.is_none() {
        return Err("no input files".into());
    }
    Ok(a)
}

fn collect(p: &Path, out: &mut Vec<PathBuf>) {
    if p.is_dir() {
        let mut entries: Vec<_> = match std::fs::read_dir(p) {
            Ok(r) => r.filter_map(|e| e.ok()).map(|e| e.path()).collect(),
            Err(_) => return,
        };
        entries.sort();
        for e in entries {
            // Skip Unity editor-only folders.
            if e.is_dir() && e.file_name().map_or(false, |n| n == "Editor") {
                continue;
            }
            collect(&e, out);
        }
    } else if p.extension().map_or(false, |e| e == "cs") {
        out.push(p.to_path_buf());
    }
}

fn main() {
    let args = match parse_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("error: {}\n\n{}", e, USAGE);
            std::process::exit(2);
        }
    };

    let catalog = match Catalog::load_embedded() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("internal error: catalog: {}", e);
            std::process::exit(1);
        }
    };
    let externs = match &args.externs {
        Some(p) => match std::fs::read_to_string(p) {
            Ok(s) => ExternTable::from_text(&s),
            Err(e) => {
                eprintln!("error: cannot read externs file {}: {}", p.display(), e);
                std::process::exit(2);
            }
        },
        None => ExternTable::load_embedded(),
    };

    if args.coverage || args.coverage_missing.is_some() {
        let missing = print_coverage(&catalog, &externs, args.coverage);
        if let Some(p) = &args.coverage_missing {
            let mut out = String::new();
            for (t, m) in &missing {
                out.push_str(t);
                out.push('\t');
                out.push_str(m);
                out.push('\n');
            }
            if let Err(e) = std::fs::write(p, out) {
                eprintln!("error: cannot write {}: {}", p.display(), e);
            }
        }
        if args.inputs.is_empty() {
            return;
        }
    }

    let mut files = Vec::new();
    for i in &args.inputs {
        collect(i, &mut files);
    }
    if files.is_empty() {
        eprintln!("error: no .cs files found");
        std::process::exit(2);
    }

    let mut units: Vec<CompilationUnit> = Vec::new();
    let mut had_error = false;
    for f in &files {
        let src = match std::fs::read_to_string(f) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("{}: error: {}", f.display(), e);
                had_error = true;
                continue;
            }
        };
        match parse_source(&src, &f.to_string_lossy()) {
            Ok(cu) => units.push(cu),
            Err(e) => {
                eprintln!("{}:{}", f.display(), e);
                had_error = true;
            }
        }
    }

    let mut diags = Diagnostics::new();
    let prog = Program::build(&units, catalog, externs, &mut diags);
    for d in &diags.items {
        if d.severity == Severity::Error || !args.quiet {
            eprintln!("{}", d);
        }
    }

    let opts = LowerOptions { base_script: args.base_script.clone(), res_prefix: args.res_prefix.clone(), class_name: args.class_name, todo_comments: true };
    if !args.check {
        if let Err(e) = std::fs::create_dir_all(&args.out) {
            eprintln!("error: cannot create {}: {}", args.out.display(), e);
            std::process::exit(2);
        }
    }

    let mut total_warn = 0usize;
    let mut total_err = 0usize;
    let mut report: BTreeMap<String, ReportEntry> = BTreeMap::new();
    for class in &prog.classes {
        let out = lower_class(&prog, class, &opts);
        let file = class.source_files.first().cloned().unwrap_or_default();
        for d in &out.diags.items {
            if d.severity == Severity::Error || !args.quiet {
                eprintln!("{}:{}", file, d);
            }
        }
        total_warn += out.diags.warning_count();
        total_err += out.diags.error_count();
        if out.diags.has_errors() {
            had_error = true;
        }
        if !args.check {
            let path = args.out.join(format!("{}.sgd", class.name));
            if let Err(e) = std::fs::write(&path, &out.source) {
                eprintln!("error: cannot write {}: {}", path.display(), e);
                had_error = true;
            } else if !args.quiet {
                println!("wrote {}", path.display());
            }
        }
        report.insert(class.name.clone(), ReportEntry { usage: out.usage, warnings: out.diags.warning_count(), errors: out.diags.error_count() });
    }

    if args.report {
        print_report(&report);
    }
    if let Some(p) = &args.report_json {
        let json = report_json(&report);
        if let Err(e) = std::fs::write(p, json) {
            eprintln!("error: cannot write {}: {}", p.display(), e);
        }
    }
    if !args.quiet {
        println!("{} class(es), {} warning(s), {} error(s)", prog.classes.len(), total_warn, total_err);
    }
    if had_error {
        std::process::exit(1);
    }
}

struct ReportEntry {
    usage: udon2godot::lower::Usage,
    warnings: usize,
    errors: usize,
}

fn print_report(report: &BTreeMap<String, ReportEntry>) {
    let mut all_unmapped: BTreeMap<String, usize> = BTreeMap::new();
    let mut all_unsupported: BTreeMap<String, usize> = BTreeMap::new();
    let mut all_unresolved: BTreeMap<String, usize> = BTreeMap::new();
    let mut mapped_total = 0usize;
    for (name, r) in report {
        println!("== {} ({} warnings, {} errors)", name, r.warnings, r.errors);
        let m: usize = r.usage.mapped.values().sum();
        mapped_total += m;
        println!("   mapped API uses: {}", m);
        if !r.usage.unmapped.is_empty() {
            println!("   unmapped:");
            for (k, v) in &r.usage.unmapped {
                println!("     {} x{}{}", k, v, if r.usage.not_udon_extern.contains(k) { "  (not an Udon extern)" } else { "" });
                *all_unmapped.entry(k.clone()).or_default() += v;
            }
        }
        if !r.usage.stubbed.is_empty() {
            println!("   stubbed (approximate/no-op mappings):");
            for (k, v) in &r.usage.stubbed {
                println!("     {} x{}", k, v);
            }
        }
        if !r.usage.unsupported.is_empty() {
            println!("   unsupported:");
            for (k, v) in &r.usage.unsupported {
                println!("     {} x{}", k, v);
                *all_unsupported.entry(k.clone()).or_default() += v;
            }
        }
        if !r.usage.unresolved.is_empty() {
            println!("   unresolved: {}", r.usage.unresolved.iter().cloned().collect::<Vec<_>>().join(", "));
            for k in &r.usage.unresolved {
                *all_unresolved.entry(k.clone()).or_default() += 1;
            }
        }
    }
    println!("== totals: {} mapped uses, {} distinct unmapped members, {} distinct unsupported, {} unresolved names", mapped_total, all_unmapped.len(), all_unsupported.len(), all_unresolved.len());
    if !all_unmapped.is_empty() {
        println!("   most-used unmapped members:");
        let mut v: Vec<_> = all_unmapped.iter().collect();
        v.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        for (k, n) in v.iter().take(40) {
            println!("     {:5}  {}", n, k);
        }
    }
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn report_json(report: &BTreeMap<String, ReportEntry>) -> String {
    let mut s = String::from("{\n");
    let mut first = true;
    for (name, r) in report {
        if !first {
            s.push_str(",\n");
        }
        first = false;
        s.push_str(&format!("  {}: {{\n", json_str(name)));
        s.push_str(&format!("    \"warnings\": {}, \"errors\": {},\n", r.warnings, r.errors));
        let map = |m: &BTreeMap<String, usize>| -> String {
            let items: Vec<String> = m.iter().map(|(k, v)| format!("{}: {}", json_str(k), v)).collect();
            format!("{{{}}}", items.join(", "))
        };
        s.push_str(&format!("    \"mapped\": {},\n", map(&r.usage.mapped)));
        s.push_str(&format!("    \"unmapped\": {},\n", map(&r.usage.unmapped)));
        s.push_str(&format!("    \"unsupported\": {},\n", map(&r.usage.unsupported)));
        s.push_str(&format!("    \"stubbed\": {},\n", map(&r.usage.stubbed)));
        let list = |v: Vec<String>| -> String { format!("[{}]", v.iter().map(|x| json_str(x)).collect::<Vec<_>>().join(", ")) };
        s.push_str(&format!("    \"not_udon_extern\": {},\n", list(r.usage.not_udon_extern.iter().cloned().collect())));
        s.push_str(&format!("    \"unresolved\": {}\n", list(r.usage.unresolved.iter().cloned().collect())));
        s.push_str("  }");
    }
    s.push_str("\n}\n");
    s
}

/// Coverage of the Udon extern list by the catalog. Array types (`FooArray`) are covered by the
/// generic `Array` mapping; component boilerplate is covered by the `Component`/`Object` bases.
/// Returns every (extern type, member) pair still unmapped.
fn print_coverage(catalog: &Catalog, externs: &ExternTable, verbose: bool) -> Vec<(String, String)> {
    let mut by_extern: BTreeMap<String, String> = BTreeMap::new();
    for t in catalog.types() {
        if let Some(e) = &t.extern_name {
            by_extern.insert(e.clone(), t.name.clone());
        }
    }
    let array_methods: std::collections::BTreeSet<String> = catalog.get("Array").map(|t| t.members.iter().map(|m| m.name.clone()).collect()).unwrap_or_default();
    let boiler = ["Equals", "GetHashCode", "GetType", "ToString", "Finalize", "MemberwiseClone", "op_Equality", "op_Inequality", "op_Implicit", "GetInstanceID", "get_destroyCancellationToken", "CompareTo", "HasFlag", "GetTypeCode"];
    let component_base: std::collections::BTreeSet<String> = ["Component", "Object", "Behaviour"].iter().flat_map(|n| catalog.chain(n)).flat_map(|t| t.members.iter().map(|m| m.name.clone())).collect();
    let mut missing: Vec<(String, String)> = Vec::new();
    let mut total_ext = 0usize;
    let mut total_mapped = 0usize;
    let mut uncovered_types: Vec<(usize, String)> = Vec::new();
    for ext in externs.type_names() {
        let methods = externs.methods_of(ext);
        total_ext += methods.len();
        let is_array = ext.ends_with("Array");
        let cat_name = by_extern.get(ext).cloned();
        let mut miss = Vec::new();
        for m in &methods {
            let base = m.strip_prefix("get_").or_else(|| m.strip_prefix("set_")).unwrap_or(m);
            if boiler.contains(&base) || base.starts_with("op_") || base.starts_with("ctor") && cat_name.as_deref().map_or(is_array, |n| !catalog.ctors(n).is_empty()) {
                continue;
            }
            let covered = if is_array {
                array_methods.contains(base) || matches!(base, "Get" | "Set" | "Length" | "LongLength" | "Rank" | "IsFixedSize" | "IsReadOnly" | "IsSynchronized" | "SyncRoot" | "GetEnumerator" | "GetLength" | "GetLongLength" | "GetLowerBound" | "GetUpperBound" | "GetValue" | "SetValue" | "Initialize" | "Address" | "Clone" | "CopyTo" | "Contains")
            } else if let Some(n) = &cat_name {
                let members = catalog.members(n, base);
                let has = if m.starts_with("set_") { members.iter().any(|mm| mm.set.is_some() || (mm.is_field() && mm.get.is_none())) } else { !members.is_empty() };
                has || component_base.contains(base) && catalog.is_a(n, "Object")
            } else {
                false
            };
            if !covered {
                miss.push(m.to_string());
            }
        }
        total_mapped += methods.len() - miss.len();
        if cat_name.is_none() && !is_array && !miss.is_empty() {
            uncovered_types.push((miss.len(), ext.to_string()));
        } else if verbose && !miss.is_empty() {
            let mut ms = miss.clone();
            ms.sort();
            println!("{} ({}): {}/{} externs mapped; missing: {}", cat_name.clone().unwrap_or_default(), ext, methods.len() - miss.len(), methods.len(), ms.join(", "));
        }
        for m in miss {
            missing.push((ext.to_string(), m));
        }
    }
    if verbose {
        uncovered_types.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        println!("== extern types with no catalog entry ({}):", uncovered_types.len());
        for (n, t) in &uncovered_types {
            println!("   {:4}  {}", n, t);
        }
    }
    println!("coverage: {}/{} externs mapped ({:.1}%); {} unmapped", total_mapped, total_ext, 100.0 * total_mapped as f64 / total_ext.max(1) as f64, missing.len());
    missing
}
