import { chromium } from '@playwright/test'
import fs from 'node:fs'
import path from 'node:path'

const label = process.env.SHOT_LABEL || 'unknown'
const base = process.env.QUEPID_BASE_URL || 'http://localhost:3000'
const out = path.join('/srv/app/tmp/shots', label)
fs.mkdirSync(out, { recursive: true })

const shot = async (page, name) => {
  await page.waitForTimeout(1200)
  await page.screenshot({ path: path.join(out, `${name}.png`), fullPage: false })
  console.log(`  captured ${name}`)
}

const browser = await chromium.launch({
  executablePath: '/usr/bin/chromium',
  args: ['--no-sandbox', '--disable-dev-shm-usage']
})
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })

try {
  await page.goto(`${base}/sessions/new`, { waitUntil: 'domcontentloaded' })
  const form = page.locator('form#login')
  await form.locator('#user_email').fill('quepid+realisticactivity@o19s.com')
  await form.locator('#user_password').fill('password')
  await form.locator('input[type="submit"][value="Sign in"]').click()
  await page.waitForLoadState('domcontentloaded')
  console.log(`logged in, at ${page.url()}`)

  await page.goto(`${base}/cases`, { waitUntil: 'domcontentloaded' })
  await shot(page, '01-cases-list')

  await page.goto(`${base}/books`, { waitUntil: 'domcontentloaded' })
  await shot(page, '02-books-list')

  const bookId = process.env.SHOT_BOOK_ID
  if (bookId) {
    await page.goto(`${base}/books/${bookId}`, { waitUntil: 'domcontentloaded' })
    await shot(page, '03-book-show')
    await page.goto(`${base}/books/${bookId}/judge`, { waitUntil: 'domcontentloaded' })
    await shot(page, '04-book-judge')
  }

  await page.goto(`${base}/teams`, { waitUntil: 'domcontentloaded' })
  await shot(page, '05-teams')
} catch (e) {
  console.log(`ERROR: ${e.message}`)
  await page.screenshot({ path: path.join(out, 'error.png') })
} finally {
  await browser.close()
}
