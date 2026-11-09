fn len(s: &str) -> usize {
    s.len()
}
fn main() {
    let r = r#"raw "quote""#;
    let c: char = '\'';
    let life: &'static str = "life";
    let v: Vec<i32> = vec![1, 2, 3];
    //! doc comment
    println!("{} {}", r, c);
}
