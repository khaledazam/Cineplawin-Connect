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

async function rotateKeys(fromVersion: number, toVersion: number) {
  const oldKey = KEYRING[fromVersion];
  const newKey = KEYRING[toVersion];

  if (!oldKey || !newKey) {
    throw new Error(`Keys for versions ${fromVersion} and ${toVersion} must be present in environment.`);
  }

  console.log(`Starting key rotation from v${fromVersion} to v${toVersion}...`);
  let cursor: string | undefined;
  let totalRotated = 0;

  while (true) {
    const contacts = await prisma.contact.findMany({
      where: { keyVersion: fromVersion },
      take: 100,
      skip: cursor ? 1 : 0,
      cursor: cursor ? { id: cursor } : undefined,
      orderBy: { id: 'asc' },
    });

    if (contacts.length === 0) break;

    for (const contact of contacts) {
      const plaintextPhone = decrypt(Buffer.from(contact.phoneEnc), oldKey);
      const reEncrypted = encrypt(plaintextPhone, newKey);

      await prisma.contact.update({
        where: { id: contact.id },
        data: {
          phoneEnc: reEncrypted,
          keyVersion: toVersion,
        },
      });

      totalRotated++;
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
