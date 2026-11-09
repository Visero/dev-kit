import Foundation

func greet(name: String) -> String {
    let message = "Hello, \(name)!"
    guard !name.isEmpty else { return "" }
    print(message)
    return message
}

struct User {
    let name: String
}
