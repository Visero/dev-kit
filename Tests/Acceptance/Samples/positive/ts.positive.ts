interface User {
  id: number;
  name: string;
  roles: Array<"admin" | "user">;
}

function findUser(id: number): User | undefined {
  return db.users.get(id) as User | undefined;
}

const u: User = { id: 1, name: "x", roles: ["user"] };
