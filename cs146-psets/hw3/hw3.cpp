#include "pin.H"
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <unistd.h>

using std::cerr;
using std::cout;
using std::endl;
using std::ofstream;
using std::string;

/* ===================================================================== */
/* Commandline Switches */
/* ===================================================================== */

KNOB<string> KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool", "o", "hw3.out",
                            "specify output file name");

KNOB<BOOL> KnobPid(KNOB_MODE_WRITEONCE, "pintool", "i", "0",
                   "append pid to output");

KNOB<UINT64> KnobBranchLimit(KNOB_MODE_WRITEONCE, "pintool", "l", "0",
                             "set limit of branches analyzed");

KNOB<UINT64> KnobHistoryBits(KNOB_MODE_WRITEONCE, "pintool", "hist", "4",
                             "sets history bits");
KNOB<UINT64> KnobHRT(KNOB_MODE_WRITEONCE, "pintool", "hrt", "1024",
                     "sets size of history register table");
KNOB<UINT64> KnobPTEntries(KNOB_MODE_WRITEONCE, "pintool", "pt", "16",
                           "sets size of pattern table");

/* ===================================================================== */
/* Global Variables */
/* ===================================================================== */
UINT64 CountSeen = 0;
UINT64 CountTaken = 0;
UINT64 CountCorrect = 0;

uint64_t history_mask = 0;
/* ===================================================================== */
/* 2-bit Branch predictor (2-bit saturating counter from figure 2)       */
/* ===================================================================== */

struct automaton2 {
  // Strongly Not taken, Weakly Not taken, Weakly Taken, Strongly Taken
  enum State : uint8_t { SN, WN, WT, ST };

  State state;
  // Initialize in Strongly Not Taken
  void init() { state = SN; }

  bool predict() const { return state >= WT; }

  void update(bool taken) {
    if (taken) {
      if (state != ST) {
        state = static_cast<State>(state + 1);
      }
    } else {
      if (state != SN) {
        state = static_cast<State>(state - 1);
      }
    }
  }
};

/* ===================================================================== */
/* Branch History Register Table                                         */
/* NOTES
history register table is indexed by branch
instruction addresses, the history register table is called
a per-address history register table. History mask decides how many
branch results to include in our history */
/* ===================================================================== */

struct bhr_entry {
  UINT64 history;

  void init() { history = 0; }
  // only presevers last history_bits number of branches
  void update(bool taken) {
    history = ((history << 1ULL) | (taken ? 1ULL : 0ULL)) & history_mask;
  }
};
/* ===================================================================== */
/*GLOBAL THAT ARE CONSTRUCTED AFTER READING KNOB VALUES                  */
/* ===================================================================== */

bhr_entry *HRT;
automaton2 *PT;

uint64_t hrt_entries = 0;
uint64_t pt_entries = 0;
uint64_t history_bits = 0;


VOID predictor_init() {
  history_bits = KnobHistoryBits.Value();
  hrt_entries = KnobHRT.Value();
  pt_entries = KnobPTEntries.Value();

  history_mask = (1UL << history_bits) - 1;

  HRT = new bhr_entry[hrt_entries];
  PT = new automaton2[pt_entries];

  for (uint64_t i = 0; i < hrt_entries; i++) {
        HRT[i].init();
  }

  for (uint64_t i = 0; i < pt_entries; i++) {
        PT[i].init();
  }
}

VOID predictor_update(ADDRINT ins_ptr, bool taken) {
  // convert ins_ptr into hrt
  uint64_t hrt_index = static_cast<uint64_t>(ins_ptr >> 2) % hrt_entries;
  UINT64 history = HRT[hrt_index].history;
  UINT64 pt_index = history % pt_entries;
  // Update pattern table automaton
  PT[pt_index].update(taken);
  // Update history
  HRT[hrt_index].update(taken);
}

bool predictor_prediction(ADDRINT ins_ptr) {
    // Get the index
    uint64_t hrt_index = static_cast<uint64_t>(ins_ptr >> 2) % hrt_entries;
    uint64_t history = HRT[hrt_index].history;
    // The prediction from the finite automaton
    return PT[history % pt_entries].predict();
  }


/* ===================================================================== */

static INT32 Usage() {
  cerr << "This pin tool collects a profile of jump/branch/call instructions "
          "for an application\n";

  cerr << KNOB_BASE::StringKnobSummary();

  cerr << endl;
  return -1;
}

/* ===================================================================== */

VOID write_results(bool limit_reached) {
  string output_file = KnobOutputFile.Value();
  if (KnobPid)
    output_file += "." + decstr(getpid());

  std::ofstream out(output_file.c_str());

  if (limit_reached)
    out << "Reason: limit reached\n";
  else
    out << "Reason: fini\n";

  out << "HistoryBits: " << history_bits << endl;
  out << "HRTEntries: " << hrt_entries << endl;
  out << "PTEntries: " << pt_entries << endl;
  out << "Count Seen: " << CountSeen << endl;
  out << "Count Taken: " << CountTaken << endl;
  out << "Count Correct: " << CountCorrect << endl;

  if (CountSeen != 0) {
    out << std::fixed << std::setprecision(6);
    out << "Accuracy: " << (double) CountCorrect / (double) CountSeen << endl;
    out << "Mispredictions: " << (CountSeen - CountCorrect) << endl;
    out << "MispredictionRate: "
        << (double) (CountSeen - CountCorrect) / (double) CountSeen << endl;
  }
  out.close();
}

/* ===================================================================== */

VOID br_predict(ADDRINT ins_ptr, INT32 taken) {
  // count the number of branches seen
  CountSeen++;
  // count the take branches
  if (taken) {
    CountTaken++;
  }

  // count the correctly predicted branches
  if (predictor_prediction(ins_ptr) == taken)
    CountCorrect++;

  // update branch prediction buffer
  predictor_update(ins_ptr, taken);

  if (CountSeen == KnobBranchLimit.Value()) {
    write_results(true);
    exit(0);
  }
}

/* ===================================================================== */
// Do not need to change instrumentation code here. Only need to modify the
// analysis code.
VOID Instruction(INS ins, void *v) {

  // The subcases of direct branch and indirect branch are
  // broken into "call" or "not call".  Call is for a subroutine
  // These are left as subcases in case the programmer wants
  // to extend the statistics to see how sub cases of branches behave

  if (INS_IsRet(ins)) {
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)br_predict, IARG_INST_PTR,
                   IARG_BRANCH_TAKEN, IARG_END);
  } else if (INS_IsSyscall(ins)) {
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)br_predict, IARG_INST_PTR,
                   IARG_BRANCH_TAKEN, IARG_END);
  } else if (INS_IsBranch(ins)) {
    if (INS_IsCall(ins)) {
      INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)br_predict, IARG_INST_PTR,
                     IARG_BRANCH_TAKEN, IARG_END);
    } else {
      INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR)br_predict, IARG_INST_PTR,
                     IARG_BRANCH_TAKEN, IARG_END);
    }
  }
}

/* ===================================================================== */

#define OUT(n, a, b)                                                           \
  out << n << " " << a << setw(16) << CountSeen.b << " " << setw(16)           \
      << CountTaken.b << endl

VOID Fini(int n, void *v) { write_results(false); }

/* ===================================================================== */

/* ===================================================================== */

int main(int argc, char *argv[]) {

  if (PIN_Init(argc, argv)) {
    return Usage();
  }

  // Required for 2-level adaptive training scheme
  predictor_init();

  INS_AddInstrumentFunction(Instruction, 0);
  PIN_AddFiniFunction(Fini, 0);

  PIN_StartProgram();

  return 0;
}

/* ===================================================================== */
/* eof */
/* ===================================================================== */
