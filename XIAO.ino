// Kaja Reinhardt
// Last Updated: 10/28/2026
// RS485 + XIAO + NTC 10K Thermistor + Atlas EZO EC
// XIAO N (Adjust per Node, 1-8)
// Listen -> take T and EC bursts -> check (QC), retake once if needed -> listen -> send -> listen
// All calculations (mean, SD, SEM, T in C, salinity) are done on the RPi
// EZO calibration: CM calibration measure, CS calibration send


#include <Arduino.h>
#include <Ezo_uart.h>
#include <HardwareSerial.h>
#include <math.h>

// Node Identifier (ID)
const String ID = "1";               // Adjust for each Node (1-8)

// Debug messages (Serial Monitor, use Data only cable)
#define DEBUG 0                      // 1 = messages on, 0 = messages off

// RS485 Setup
HardwareSerial RS485Serial(1);       // UART 1 = RS485 bus to the RPi
const int RX_485 = 6;
const int TX_485 = 5;
const int DE_RE = 3;                 // HIGH = sending, LOW = listening

// Thermistor Setup 
const int THERMISTOR = 9;            // XIAO GPIO 9
const int T_SAMPLE_DELAY = 5;        // ms between readings in a burst

// Atlas EZO-EC Setup
HardwareSerial ECSerial(2);          // UART 2 = EZO-EC
const int RX_EC = 44;
const int TX_EC = 43;
Ezo_uart EC(ECSerial, "ECraw");

// Fail value (invalid: negative, 0.000 or not a number)
// Hawaii (deployment location) water Temp > 0 deg
// EC = 0.000 would be DI water
const float READ_FAIL = 999999;

// Burst settings
// Changes = edit CoSTA.conf + new upload to every XIAO
const int   T_SAMPLES = 20;          // readings per burst
const int   T_BURST_MIN = 15;        // valid readings needed, otherwise retake
// ---CHANGE after Calibration---
const float T_SPREAD_MAX = 0;        // max SD of burst, 0 = no cut-off 
const int   EC_SAMPLES = 20;         // readings per burst
const int   EC_BURST_MIN = 15;       // valid readings needed, otherwise retake
// ---CHANGE after Calibration---
const float EC_SPREAD_MAX = 0;        // max SD of burst, 0 = no cut-off 

// Thermistor burst data
float  tempV[T_SAMPLES];
String tRun = "";        // 1 = first burst ok, 2 = retake ok, F = retake failed
int    tBad = 0;         // number of invalid readings in the burst

// EC burst data
float  ECraw[EC_SAMPLES];
String ecRun = "";       // same logic as Thermistor
int    ecBad = 0;        

// Measurment state
String lastTimestamp = "";      // TimeStamp from M command, sent back with data
bool   haveData = false;        // true once bursts taken 
String calAnswer = "";          // EZO answer to last CM command, sent back CS

void setup() {
  Serial.begin(115200);                // Serial Monitor (debug messages on laptop)

  // RS485
  RS485Serial.begin(9600, SERIAL_8N1, RX_485, TX_485);   // 9600 baud, 8 bits, no parity, 1 stop bit
  pinMode(DE_RE, OUTPUT);
  digitalWrite(DE_RE, LOW);            // listening

  // Thermistor
  analogReadResolution(12);            // 12 bit ADC (0-4095)

  // Atlas
  ECSerial.begin(9600, SERIAL_8N1, RX_EC, TX_EC);        // EZO default (same as RS485)
  // Clean up first EZO read
  EC.send_cmd_no_resp("C,0");        // turn OFF continuous streaming
  delay(150);
  EC.send_cmd_no_resp("Response,0"); // turn OFF "*OK"
  delay(150);
  EC.flush_rx_buffer();

  EC.send_cmd_no_resp("T,25.00");    // set T compensation to 25 = no compensation
  delay(300);
  EC.flush_rx_buffer();

  debug("Node " + ID + " ready");
}

void loop() {
  if (RS485Serial.available()) {

    // String will be (ID, Command, Date/Time or EZO command)
    String incoming = RS485Serial.readStringUntil('\n');  // listening
    readMessage(incoming);
  }
}

void readMessage(String incoming) {
  incoming.trim();                                  // remove \r, spaces
  if (incoming.length() == 0) return;

  debug("Received: " + incoming);

  // Get target ID from string
  int firstComma = incoming.indexOf(',');
  if (firstComma == -1) {
    debug("ignored");
    return;
  }

  String targetID = incoming.substring(0, firstComma);
  String rest = incoming.substring(firstComma + 1);

  bool addressedToMe = (targetID == ID) || (targetID == "0");  // 0 = broadcast

  if (!addressedToMe) {
    debug("Not me");
    return;
  }

  // Get Command from string
  int secondComma = rest.indexOf(',');
  String command;
  String payload = "";
  if (secondComma == -1) {
    command = rest;                                 // S or CS with no payload
  }
  else {
    command = rest.substring(0, secondComma);
    payload = rest.substring(secondComma + 1);      // timestamp for M, EZO command for CM
  }

  // Safety Net = Broadcast only valid for commands M and CM 
  if (targetID == "0" && command != "M" && command != "CM") {
    debug("Broadcast only for M and CM - ignored");
    return;
  }

  if (command == "M") {                             // Measure command
    lastTimestamp = payload;
    debug("Measure command received - taking bursts...");
    takeReadings();                                 // makes the measurement
  }
  else if (command == "S") {                        // Send command
    debug("Send command received - transmitting stored bursts...");
    sendReading();
  }
  else if (command == "CM") {                       // Calibration command -> EZO
    debug("Calibration command received: " + payload);
    calibrateEC(payload);                           // answer is stored, not sent
  }
  else if (command == "CS") {                       // Calibration send command
    debug("Calibration send command received - transmitting EZO answer...");
    sendCalibration();
  }

  else {
    debug("Unknown command");
  }
}

void takeReadings() {
  haveData = false;

  // THERMISTOR: burst -> QC -> retake once if QC fails

  tRun = "1";                     // first run
  takeTBurst();
  if (!burstOK(tempV, T_SAMPLES, T_BURST_MIN, T_SPREAD_MAX)) {
    debug("T burst failed QC - retake");
    tRun = "2";                   // failed -> second run
    takeTBurst();
    if (!burstOK(tempV, T_SAMPLES, T_BURST_MIN, T_SPREAD_MAX)) tRun = "F";
  }
  tBad = countBad(tempV, T_SAMPLES);

  // ELECTRIC CONDUCTIVITY: burst -> QC -> retake once if QC fails

  ecRun = "1";                    // first run
  takeECBurst();
  if (!burstOK(ECraw, EC_SAMPLES, EC_BURST_MIN, EC_SPREAD_MAX)) {
    debug("EC burst failed QC - retake");
    ecRun = "2";                  // failed, second run
    takeECBurst();
    if (!burstOK(ECraw, EC_SAMPLES, EC_BURST_MIN, EC_SPREAD_MAX)) ecRun = "F";
  }
  ecBad = countBad(ECraw, EC_SAMPLES);

  haveData = true;
  clearBus();                  // requests came in during  measuring = old = delete

  debug("T " + tRun + "/" + tBad + " | EC " + ecRun + "/" + ecBad); 
}

void takeTBurst() {
  for (int i = 0; i < T_SAMPLES; i++) {
    tempV[i] = readT();
    delay(T_SAMPLE_DELAY);                 // 5 ms between readings
  }
}

void takeECBurst() {
  for (int i = 0; i < EC_SAMPLES; i++) {
    ECraw[i] = readEC();                   // ~600 ms per EZO reading
  }
}

// Check each thermistor reading [V]
float readT() {
  float v = analogReadMilliVolts(THERMISTOR) / 1000.0;   // mV -> V
  return isValid(v) ? v : READ_FAIL;    // READ_FAIL if invalid
}

// Check each EC reading [uS/cm]
float readEC() {
  float ec = READ_FAIL;                 // READ_FAIL if invalid
  if (EC.send_read()) {                 // "R" to the EZO, true if it answered
    float reading = EC.get_reading();
    if (isValid(reading)) ec = reading;
  }
  EC.flush_rx_buffer();
  return ec;
}

// Valid = a number above 0 (used above)
bool isValid(float x) {
  return isfinite(x) && x > 0;
}

// Quality Control: Check BURST_MIN and SPREAD_MAX
bool burstOK(const float *x, int n, int minValid, float sdMax) {
  int valid = 0;
  double sum = 0;
  for (int i = 0; i < n; i++) {
    if (x[i] != READ_FAIL) { valid++; sum += x[i]; }
  }
  if (valid < minValid) return false;              // hard fail: too many invalid readings
  if (sdMax <= 0) return true;                     // no spread cut-off

  double mean = sum / valid;
  double ss = 0;
  for (int i = 0; i < n; i++) {
    if (x[i] != READ_FAIL) ss += (x[i] - mean) * (x[i] - mean);
  }
  return sqrt(ss / (valid - 1)) <= sdMax;          // spread QC: SD (N - 1) of the valid readings
}

int countBad(const float *x, int n) {
  int bad = 0;
  for (int i = 0; i < n; i++) {
    if (x[i] == READ_FAIL) bad++;
  }
  return bad;
}

// Delete old messages
void clearBus() {
  while (RS485Serial.available()) RS485Serial.read();
}

void sendReading() {
  transmitOn();

  if (!haveData) {
    // No measure command / missed the broadcast
    RS485Serial.print("NODATA,"); RS485Serial.println(ID);
  }
  else {
    // DATA,TS,ID,T_run,T_bad,EC_run,EC_bad,T_V x T_SAMPLES,EC x EC_SAMPLES
    RS485Serial.print("DATA,"); RS485Serial.print(lastTimestamp);   
    RS485Serial.print(","); RS485Serial.print(ID);
    RS485Serial.print(","); RS485Serial.print(tRun);
    RS485Serial.print(","); RS485Serial.print(tBad);
    RS485Serial.print(","); RS485Serial.print(ecRun);
    RS485Serial.print(","); RS485Serial.print(ecBad);
    for (int i = 0; i < T_SAMPLES; i++)  printValue(tempV[i], 3);
    for (int i = 0; i < EC_SAMPLES; i++) printValue(ECraw[i], 2);
    RS485Serial.println();
  }

  transmitOff();
}

// ",reading" (999999 = invalid reading)
void printValue(float x, int decimals) {
  RS485Serial.print(",");
  RS485Serial.print(x, decimals);
}

// EZO calibration: pass one command to the EZO and keep its answer
// Cal,clear / Cal,dry / Cal,low,12880 / Cal,high,80000 / Cal,? / R
// Calibration is stored on EZO itself = stays when chain is off
void calibrateEC(String cmd) {
  calAnswer = "";                                  // forget the last answer

  EC.send_cmd_no_resp("Response,1");               // turn ON "*OK" / "*ER" so the answer shows if it worked
  delay(300);
  EC.flush_rx_buffer();                            // drop the *OK of Response,1

  EC.send_cmd_no_resp(cmd.c_str());                // the calibration command

  unsigned long start = millis();
  while (millis() - start < 1500) {                // Cal and R take ~600 ms
    if (ECSerial.available()) {
      char c = ECSerial.read();
      calAnswer += (c == '\r') ? ' ' : c;          // e.g. "*OK", "?CAL,2 *OK", "12880.00 *OK"
    }
  }
  calAnswer.trim();
  if (calAnswer.length() == 0) calAnswer = "NOANSWER";  // EZO did not answer

  EC.send_cmd_no_resp("Response,0");               // back to the monitoring setting (also reset at every start-up)
  delay(300);
  EC.flush_rx_buffer();

  clearBus();                                      // requests came in during calibration = old = delete

  debug("EZO answer: " + calAnswer);
}

void sendCalibration() {
  transmitOn();

  if (calAnswer.length() == 0) {
    // No calibration command / missed broadcast
    RS485Serial.print("NOCAL,"); RS485Serial.println(ID);
  }
  else {
    // CAL,ID,EZO answer
    RS485Serial.print("CAL,"); RS485Serial.print(ID);
    RS485Serial.print(","); RS485Serial.println(calAnswer);
  }

  transmitOff();
}

void transmitOn() {
  digitalWrite(DE_RE, HIGH);   // sending
  delay(2);                    // transceiver settle
}

void transmitOff() {
  RS485Serial.flush();         // wait until the last byte is out
  delay(2);
  digitalWrite(DE_RE, LOW);    // listening
}

// Message to the Serial Monitor, only if DEBUG is 1
void debug(const String &msg) {
#if DEBUG
  Serial.println(msg);
#endif
}
