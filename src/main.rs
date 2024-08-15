mod author;
mod categories;
mod disciplines;
mod model;

use std::env::args;
use std::fs;
use std::io;
use std::path::Path;

use anyhow::{bail, Context};
use flate2::write::GzEncoder;
use semver::Version;
use tar::Builder;
use typst_syntax::package::{PackageManifest, UnknownFields};
use unicode_ident::{is_xid_continue, is_xid_start};

use self::author::validate_author;
use self::categories::validate_category;
use self::disciplines::validate_discipline;

fn main() -> anyhow::Result<()> {
    println!("Starting bundling.");

    let mut next_is_out = false;
    let pkg_dir = args()
        .skip(1)
        .find(|arg| {
            if next_is_out {
                return true;
            }
            next_is_out = arg == "--pkg-dir" || arg == "-d";
            false
        })
        .unwrap();

    let pkg_dir = Path::new(&pkg_dir);

    let mut next_is_out = false;
    let out_dir = args()
        .skip(1)
        .find(|arg| {
            if next_is_out {
                return true;
            }
            next_is_out = arg == "--out-dir" || arg == "-o";
            false
        })
        .unwrap();

    let out_dir = Path::new(&out_dir);
    let mut namespace_errors = vec![];

    let mut buf = vec![];
    let compressed = flate2::write::GzEncoder::new(&mut buf, flate2::Compression::default());
    let mut builder = tar::Builder::new(compressed);

    for entry in walkdir::WalkDir::new(pkg_dir)
        .min_depth(1)
        .max_depth(1)
        .sort_by_file_name()
    {
        let entry = entry?;
        if !entry.metadata()?.is_dir() {
            continue;
        }

        let path = entry.into_path();
        let namespace = path
            .file_name()
            .context("cannot read namespace folder name")?
            .to_str()
            .context("invalid namespace")?;

        println!("Processing namespace: {}", namespace);

        let mut package_errors = vec![];

        for entry in walkdir::WalkDir::new(&path).min_depth(2).max_depth(2) {
            let entry = entry?;
            if !entry.metadata()?.is_dir() {
                bail!(
                    "{}: a package directory may only contain version sub-directories, not files.",
                    entry.path().display()
                );
            }

            let path = entry.into_path();

            if path
                .file_name()
                .and_then(|name| name.to_str())
                .and_then(|name| Version::parse(name).ok())
                .is_none()
            {
                bail!(
                    "{}: Directory is not a valid version number",
                    path.display()
                );
            }

            match process_package(&path, namespace, &mut builder, pkg_dir)
                .with_context(|| format!("failed to process package at {}", path.display()))
            {
                Ok(_) => {}
                Err(err) => package_errors.push(err),
            }
        }

        if !package_errors.is_empty() {
            namespace_errors.push((namespace.to_string(), package_errors));
        }
    }

    println!("Done.");

    builder.finish()?;
    drop(builder);
    validate_archive(&buf).context("failed to validate archive")?;
    write_archive(&buf, out_dir).context("failed to write archive")?;

    if !namespace_errors.is_empty() {
        eprintln!("Failed to process some packages:");
        for (namespace, errors) in namespace_errors {
            eprintln!("  Namespace: {}", namespace);
            for error in errors {
                eprintln!("    {:#}", error);
            }
        }

        std::process::exit(1);
    }

    Ok(())
}

/// Ensures that the archive can be decompressed and read.
fn validate_archive(buf: &[u8]) -> anyhow::Result<()> {
    let decompressed = flate2::read::GzDecoder::new(io::Cursor::new(&buf));
    let mut tar = tar::Archive::new(decompressed);
    for entry in tar.entries()? {
        let _ = entry?;
    }
    Ok(())
}

/// Write a compressed archive to the output directory.
fn write_archive(buf: &[u8], out_dir: &Path) -> anyhow::Result<()> {
    fs::write(out_dir, buf)?;
    Ok(())
}

/// Create an archive for a package.
fn process_package(
    path: &Path,
    namespace: &str,
    builder: &mut Builder<GzEncoder<&mut Vec<u8>>>,
    pkg_dir: &Path,
) -> anyhow::Result<()> {
    println!("Bundling {}.", path.display());

    let manifest =
        parse_manifest(path, namespace, pkg_dir).context("failed to parse package manifest")?;
    bundle_package(path, &manifest, builder, pkg_dir).context("failed to bundle package")?;

    Ok(())
}

fn validate_no_unknown_fields(
    unknown_fields: &UnknownFields,
    key: Option<&str>,
) -> anyhow::Result<()> {
    if !unknown_fields.is_empty() {
        match key {
            Some(key) => bail!(
                "unknown fields in `{key}`: {:?}",
                unknown_fields.keys().collect::<Vec<_>>()
            ),
            None => bail!(
                "unknown fields: {:?}",
                unknown_fields.keys().collect::<Vec<_>>()
            ),
        }
    }

    Ok(())
}

/// Read and validate the package's manifest.
fn parse_manifest(path: &Path, namespace: &str, pkg_dir: &Path) -> anyhow::Result<PackageManifest> {
    let src = fs::read_to_string(path.join("typst.toml"))?;

    let manifest: PackageManifest = toml::from_str(&src)?;
    let expected = format!(
        "{namespace}/{}/{}",
        manifest.package.name, manifest.package.version
    );

    validate_no_unknown_fields(&manifest.unknown_fields, None)?;
    validate_no_unknown_fields(&manifest.package.unknown_fields, Some("package"))?;

    if path.strip_prefix(pkg_dir)? != Path::new(&expected) {
        bail!("package directory name and manifest are mismatched");
    }

    if !is_ident(&manifest.package.name) {
        bail!("package name is not a valid identifier");
    }

    for author in &manifest.package.authors {
        validate_author(author).context("error while checking author name")?;
    }

    if manifest.package.description.is_none() {
        bail!("package description is missing");
    }

    if manifest.package.categories.len() > 3 {
        bail!("package can have at most 3 categories");
    }

    for category in &manifest.package.categories {
        validate_category(category)?;
    }

    for discipline in &manifest.package.disciplines {
        validate_discipline(discipline)?;
    }

    let Some(license) = &manifest.package.license else {
        bail!("package license is missing");
    };

    let license =
        spdx::Expression::parse(license).context("failed to parse SPDX license expression")?;

    for requirement in license.requirements() {
        let id = requirement
            .req
            .license
            .id()
            .context("license must not contain a referencer")?;

        if !id.is_osi_approved() {
            bail!("license is not OSI approved: {}", id.full_name);
        }
    }

    let entrypoint = path.join(manifest.package.entrypoint.as_str());
    validate_typst_file(&entrypoint, "package entrypoint")?;

    if let Some(template) = &manifest.template {
        validate_no_unknown_fields(&template.unknown_fields, Some("template"))?;

        if manifest.package.categories.is_empty() {
            bail!("template packages must have at least one category");
        }

        let entrypoint = path
            .join(template.path.as_str())
            .join(template.entrypoint.as_str());
        validate_typst_file(&entrypoint, "template entrypoint")?;
    }

    Ok(manifest)
}

/// Bundle the package according to the manifest
fn bundle_package(
    dir_path: &Path,
    manifest: &PackageManifest,
    builder: &mut Builder<GzEncoder<&mut Vec<u8>>>,
    pkg_dir: &Path,
) -> anyhow::Result<()> {
    let mut overrides = ignore::overrides::OverrideBuilder::new(dir_path);
    for exclusion in &manifest.package.exclude {
        if exclusion.starts_with('!') {
            bail!("globs with '!' are not supported");
        }
        let exclusion = exclusion.trim_start_matches("./");
        overrides.add(&format!("!{}", exclusion))?;
    }

    // Always ignore the thumbnail.
    if let Some(template) = &manifest.template {
        overrides.add(&format!("!{}", template.thumbnail))?;
    }

    // Iterate over excluded files
    for entry in ignore::WalkBuilder::new(dir_path)
        .overrides(overrides.build()?)
        .sort_by_file_name(|a, b| a.cmp(b))
        .build()
    {
        let entry = entry?;
        let file_path = entry.path();
        let mut local_path = file_path.strip_prefix(pkg_dir)?;
        if local_path.as_os_str().is_empty() {
            local_path = Path::new(".");
        }
        println!("  Adding {}", local_path.display());
        builder.append_path_with_name(file_path, local_path)?;
    }
    Ok(())
}

/// Check that a Typst file exists, its name ends in `.typ`, and that it is valid
/// UTF-8.
fn validate_typst_file(path: &Path, name: &str) -> anyhow::Result<()> {
    if !path.exists() {
        bail!("{name} is missing");
    }

    if path.extension().map_or(true, |ext| ext != "typ") {
        bail!("{name} must have a .typ extension");
    }

    fs::read_to_string(path).context("failed to read {name} file")?;
    Ok(())
}

/// Whether a string is a valid Typst identifier.
fn is_ident(string: &str) -> bool {
    let mut chars = string.chars();
    chars
        .next()
        .is_some_and(|c| is_id_start(c) && chars.all(is_id_continue))
}

/// Whether a character can start an identifier.
fn is_id_start(c: char) -> bool {
    is_xid_start(c) || c == '_'
}

/// Whether a character can continue an identifier.
fn is_id_continue(c: char) -> bool {
    is_xid_continue(c) || c == '_' || c == '-'
}
