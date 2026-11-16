import bcrypt from "bcryptjs";
import jwt from "jsonwebtoken";
import { TOKEN_TTL, loadJwtSecret } from "./config.js";

const JWT_SECRET = loadJwtSecret();

/** Hash a plaintext password with bcrypt (10 rounds). */
export function hashPassword(password) {
  return bcrypt.hashSync(password, 10);
}

/** Constant-time-ish password check via bcrypt. */
export function verifyPassword(password, hash) {
  try {
    return bcrypt.compareSync(password, hash);
  } catch {
    return false;
  }
}

/** Issue a stateless session token for an account. */
export function signToken(account) {
  return jwt.sign(
    { account_id: account.id, username: account.username },
    JWT_SECRET,
    { expiresIn: TOKEN_TTL },
  );
}

/** Verify a token and return its payload, or null when invalid/expired. */
export function verifyToken(token) {
  try {
    return jwt.verify(token, JWT_SECRET);
  } catch {
    return null;
  }
}
