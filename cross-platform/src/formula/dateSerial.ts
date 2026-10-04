/** Excel date serial numbers: whole days since 1899-12-30, with the time of day as the fraction. */

const div = (a: number, b: number) => Math.trunc(a / b);

/** Days since 1970-01-01 for a proleptic Gregorian date (Hinnant's algorithm). */
function daysFromCivil(year: number, m: number, d: number): number {
  const y = m <= 2 ? year - 1 : year;
  const era = div(y >= 0 ? y : y - 399, 400);
  const yoe = y - era * 400;
  const mp = (m + 9) % 12;
  const doy = div(153 * mp + 2, 5) + d - 1;
  const doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy;
  return era * 146097 + doe - 719468;
}

function civilFromDays(days: number): { year: number; month: number; day: number } {
  const z = days + 719468;
  const era = div(z >= 0 ? z : z - 146096, 146097);
  const doe = z - era * 146097;
  const yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100));
  const mp = div(5 * doy + 2, 153);
  const d = doy - div(153 * mp + 2, 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  return { year: m <= 2 ? y + 1 : y, month: m, day: d };
}

/** 1899-12-30 is 25569 days before 1970-01-01. */
const EPOCH_OFFSET = 25569;

/** DATE(y, m, d) with Excel's overflow rules (month 13 → next year, day 0 → last day of previous month). */
export function dateSerial(year: number, month: number, day: number): number {
  let y = year;
  if (y < 1900) y += 1900;
  const totalMonths = y * 12 + (month - 1);
  const normalizedYear = Math.floor(totalMonths / 12);
  const normalizedMonth = totalMonths - normalizedYear * 12 + 1;
  return daysFromCivil(normalizedYear, normalizedMonth, 1) + (day - 1) + EPOCH_OFFSET;
}

export function dateComponents(serial: number) {
  return civilFromDays(Math.floor(serial) - EPOCH_OFFSET);
}

/** Hours, minutes, seconds of the fractional part (rounded to the nearest second). */
export function timeComponents(serial: number) {
  const fraction = serial - Math.floor(serial);
  let seconds = Math.round(fraction * 86400);
  if (seconds >= 86400) seconds = 86399;
  return { hour: Math.floor(seconds / 3600), minute: Math.floor((seconds % 3600) / 60), second: seconds % 60 };
}

/** 1 = Sunday … 7 = Saturday. */
export function weekday(serial: number): number {
  const days = Math.floor(serial);
  return (((days + 6) % 7) + 7) % 7 + 1;
}

export function daysInMonth(year: number, month: number): number {
  return dateSerial(year, month + 1, 1) - dateSerial(year, month, 1);
}

export const isLeapYear = (y: number) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;

/** The serial for a moment, in local time. */
export function serialFromDate(date: Date): number {
  const seconds = date.getTime() / 1000 - date.getTimezoneOffset() * 60;
  return seconds / 86400 + EPOCH_OFFSET;
}

export function addMonths(start: number, months: number): number {
  const { year, month, day } = dateComponents(start);
  const target = dateSerial(year, month + months, 1);
  const t = dateComponents(target);
  return target + Math.min(day, daysInMonth(t.year, t.month)) - 1;
}

export const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
export const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
