/* outer /* inner */ still alive */
let a = #"raw "quote" inside"#
let b = ##("hash(")##)
#if swift(>=5.9)
let c = 1
#endif
print("a = \(a) b = \(b)")
