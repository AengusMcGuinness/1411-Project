#include <unistd.h>
#include <iostream>
#include <iomanip>
#include <fstream>
#include <map>
#include <cstdlib>
#include "pin.H"

using std::ofstream;
using std::cout;
using std::cerr;
using std::endl;
using std::string;

/* ===================================================================== */
/* Commandline Switches */
/* ===================================================================== */

KNOB<string> KnobOutputFile(KNOB_MODE_WRITEONCE,         "pintool",
                            "o", "hw3.out", "specify output file name");

KNOB<BOOL>   KnobPid(KNOB_MODE_WRITEONCE,                "pintool",
                            "i", "0", "append pid to output");

KNOB<UINT64> KnobBranchLimit(KNOB_MODE_WRITEONCE, "pintool", "l", "0",
                             "set limit of branches analyzed");

KNOB<UINT64> KnobBPBSize(KNOB_MODE_WRITEONCE, "pintool",
                         "b", "1024", "set branch prediction buffer size");
/* ===================================================================== */
/* Global Variables */
/* ===================================================================== */
UINT64 CountSeen = 0;
UINT64 CountTaken = 0;
UINT64 CountCorrect = 0;

/* ===================================================================== */
/* 1-bit Branch predictor (using Branch Prediction Buffer),              */
/* which is mentioned in cs246-lecture-speculation.pdf but with 1-bit    */
/* ===================================================================== */
UINT64 BPBSize = 0;
UINT64 mask = 0;

struct entry_one_bit {
    bool prediction;
};

entry_one_bit *BPB_one_bit = nullptr;

/* initialize the BPB, not taken by default*/
VOID BPB_init() {
    BPBSize = KnobBPBSize.Value();
    mask = BPBSize - 1;
    BPB_one_bit = new entry_one_bit[BPBSize];

    for(UINT64 i = 0; i < BPBSize; i++)
    {
        BPB_one_bit[i].prediction = false;
    }
}

/* return the prediction for the given instruction */
bool BPB_prediction(ADDRINT ins_ptr)
{
    UINT64 index;

    index = mask & ins_ptr;
    
    return BPB_one_bit[index].prediction;
}

/* update the BPB entry */
VOID BPB_update(ADDRINT ins_ptr, bool taken)
{
    UINT64 index;

    index = mask & ins_ptr;

    BPB_one_bit[index].prediction = taken;
}


/* ===================================================================== */


/* ===================================================================== */

static INT32 Usage()
{
    cerr << "This pin tool collects a profile of jump/branch/call instructions for an application\n";

    cerr << KNOB_BASE::StringKnobSummary();

    cerr << endl;
    return -1;
}

/* ===================================================================== */

VOID write_results(bool limit_reached)
{
    string output_file = KnobOutputFile.Value();
    if(KnobPid) output_file += "." + decstr(getpid());
    
    std::ofstream out(output_file.c_str());

    if(limit_reached)
        out << "Reason: limit reached\n";
    else
      out << "Reason: fini\n";
    out << "BPB Size: " << BPBSize << endl;        
    out << "Count Seen: " << CountSeen << endl;
    out << "Count Taken: " << CountTaken << endl;
    out << "Count Correct: " << CountCorrect << endl;
    out.close();
}

/* ===================================================================== */

VOID br_predict(ADDRINT ins_ptr, INT32 taken)
{
    //count the number of branches seen
	CountSeen++;
	//count the take branches
	if (taken){
			CountTaken++;
	}
	
	
	//count the correctly predicted branches
	if(BPB_prediction(ins_ptr) == taken) 
		CountCorrect++;

	//update branch prediction buffer
	BPB_update(ins_ptr, taken);

    if(CountSeen == KnobBranchLimit.Value())
    {
        write_results(true);
        exit(0);
    }
} 


/* ===================================================================== */
// Do not need to change instrumentation code here. Only need to modify the analysis code. 
VOID Instruction(INS ins, void *v)
{

// The subcases of direct branch and indirect branch are
// broken into "call" or "not call".  Call is for a subroutine
// These are left as subcases in case the programmer wants
// to extend the statistics to see how sub cases of branches behave

    if( INS_IsRet(ins) )
    {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR) br_predict, 
            IARG_INST_PTR, IARG_BRANCH_TAKEN,  IARG_END);
    }
    else if( INS_IsSyscall(ins) )
    {
        INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR) br_predict, 
            IARG_INST_PTR, IARG_BRANCH_TAKEN,  IARG_END);
    }
    else if (INS_IsBranch(ins))
    {
        if( INS_IsCall(ins) ) {
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR) br_predict, 
                IARG_INST_PTR, IARG_BRANCH_TAKEN,  IARG_END);
        }
        else {
            INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR) br_predict, 
                IARG_INST_PTR, IARG_BRANCH_TAKEN,  IARG_END);
        }
    }
    
}

/* ===================================================================== */

#define OUT(n, a, b) out << n << " " << a << setw(16) << CountSeen. b  << " " << setw(16) << CountTaken. b << endl

VOID Fini(int n, void *v)
{
    write_results(false);
}


/* ===================================================================== */


/* ===================================================================== */

int main(int argc, char *argv[])
{
    
    if( PIN_Init(argc,argv) )
    {
        return Usage();
    }

    BPB_init();
        
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddFiniFunction(Fini, 0);

    PIN_StartProgram();
    
    return 0;
}

/* ===================================================================== */
/* eof */
/* ===================================================================== */
