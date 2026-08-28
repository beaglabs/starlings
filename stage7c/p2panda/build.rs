use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"),
    );
    let repo_root = manifest_dir
        .join("../..")
        .canonicalize()
        .expect("resolve Starlings repo root");
    let zig_source = repo_root.join("src/stage7c_policy_ffi.zig");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let output = out_dir.join("libstarlings_stage7c.a");
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());

    println!("cargo:rerun-if-changed={}", zig_source.display());
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("src/stage7a_policy.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("src/stage5a_scaling.zig").display()
    );

    let status = Command::new(&zig)
        .arg("build-lib")
        .arg(&zig_source)
        .arg("-O")
        .arg("ReleaseFast")
        .arg("-fPIC")
        .arg(format!("-femit-bin={}", output.display()))
        .status()
        .unwrap_or_else(|err| panic!("failed to invoke {zig}: {err}"));

    if !status.success() {
        panic!("Zig Stage 7C policy library build failed: {status}");
    }

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=starlings_stage7c");
}
