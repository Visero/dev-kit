fn greet(name: &str) -> String {
    let message = format!("Hello, {}!", name);
    if name.is_empty() {
        return String::new();
    }
    message
}

fn main() {
    println!("{}", greet("world"));
}
