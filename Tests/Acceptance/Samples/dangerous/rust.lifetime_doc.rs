//! Module-level inner doc comment (valid at top of file).
//! This is the correct placement for `//!`.

fn len(s: &str) -> usize {
    s.len()
}

fn main() {
    let r = r#"raw "quote" inside"#;
    let c: char = '\'';
    let life: &'static str = "life";
    let v: Vec<i32> = vec![1, 2, 3];
    println!("{} {} {} {}", r, c, life, v.len());
}
