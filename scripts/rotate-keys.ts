/**
 * Wassel (واصل): Online Zero-Downtime Keyring Rotation Script (Scenario 2)
 *
 * Re-encrypts Contact.phoneEnc records from an older keyVersion to the current keyVersion.
 * Run via CLI: npx ts-node scripts/rotate-keys.ts --from 1 --to 2
 */

import { PrismaClient } from '@prisma/client';
import * as crypto from 'crypto';

const prisma = new PrismaClient();

const KEYRING: Record<number, Buffer> = {
  1: Buffer.from(process.env.APP_ENCRYPTION_KEY_V1 || '', 'hex'),
  2: Buffer.from(process.env.APP_ENCRYPTION_KEY_V2 || process.env.APP_ENCRYPTION_KEY || '', 'hex'),
};

const HMAC_KEYRING: Record<number, Buffer> = {
  1: Buffer.from(process.env.APP_HMAC_KEY_V1 || '', 'hex'),
  2: Buffer.from(process.env.APP_HMAC_KEY_V2 || process.env.APP_HMAC_KEY || '', 'hex'),
};

function decrypt(ciphertext: Buffer, key: Buffer): string {
  const iv = ciphertext.subarray(0, 12);
  const tag = ciphertext.subarray(12, 28);
  const encrypted = ciphertext.subarray(28);

  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);
  return decipher.update(encrypted, undefined, 'utf8') + decipher.final('utf8');
}

function encrypt(plaintext: string, key: Buffer): Buffer {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, encrypted]);
}

function computeBlindIndex(tenantId: string, phone: string, hmacKey: Buffer): string {
  return crypto.createHmac('sha256', hmacKey).update(`${tenantId}:${phone}`).digest('hex');
}

async function rotateKeys(fromVersion: number, toVersion: number) {
  const oldKey = KEYRING[fromVersion];
  const newKey = KEYRING[toVersion];
  const oldHmacKey = HMAC_KEYRING[fromVersion];
  const newHmacKey = HMAC_KEYRING[toVersion];

  if (!oldKey || oldKey.length !== 32 || !newKey || newKey.length !== 32) {
    throw new Error(`Valid 32-byte AES keys for versions ${fromVersion} and ${toVersion} must be present in environment.`);
  }

  if (!oldHmacKey || oldHmacKey.length === 0 || !newHmacKey || newHmacKey.length === 0) {
    throw new Error(`Valid HMAC keys for versions ${fromVersion} and ${toVersion} must be present in environment.`);
  }

  console.log(`Starting key rotation from v${fromVersion} to v${toVersion}...`);
  let cursor: string | undefined;
  let totalRotated = 0;

  while (true) {
    // Crucial: Filter out anonymized contacts (where phoneEnc is random bytes and must never be decrypted)
    const contacts = await prisma.contact.findMany({
      where: {
        keyVersion: fromVersion,
        anonymizedAt: null,
      },
      take: 100,
      skip: cursor ? 1 : 0,
      cursor: cursor ? { id: cursor } : undefined,
      orderBy: { id: 'asc' },
    });

    if (contacts.length === 0) break;

    for (const contact of contacts) {
      const plaintextPhone = decrypt(Buffer.from(contact.phoneEnc), oldKey);
      const reEncrypted = encrypt(plaintextPhone, newKey);
      const newPhoneHash = computeBlindIndex(contact.tenantId, plaintextPhone, newHmacKey);

      // Guarded update ensures we don't overwrite if touched concurrently
      const updated = await prisma.contact.updateMany({
        where: {
          id: contact.id,
          keyVersion: fromVersion,
          anonymizedAt: null,
        },
        data: {
          phoneEnc: reEncrypted,
          phoneHash: newPhoneHash,
          keyVersion: toVersion,
        },
      });

      if (updated.count > 0) {
        totalRotated++;
      }
    }

    cursor = contacts[contacts.length - 1].id;
    console.log(`Rotated ${totalRotated} contacts so far...`);
  }

  console.log(`Key rotation complete! Total contacts updated: ${totalRotated}`);
}

const fromVer = parseInt(process.argv[3] || '1', 10);
const toVer = parseInt(process.argv[5] || '2', 10);

rotateKeys(fromVer, toVer)
  .catch((err) => {
    console.error('Key rotation failed:', err);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
