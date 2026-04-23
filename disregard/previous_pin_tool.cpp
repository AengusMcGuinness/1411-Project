#include <unistd.h>
#include <iostream>
#include <fstream>
#include <cmath>
#include <algorithm>
#include <sstream>

#include "pin.H"

// Number of bits in the address
const static UINT64 ADDRESS_SIZE = 64;

// Defines the Structure of a Cache Entry
// LRU_status stores the adges of a cache line
// if LRU_status == 0, the cache line is Most Recently Used.
// else if LRU_status == assoc - 1, the cache line is one of the oldest cache lines.
struct cacheEntry
{
    int LRU_status;
    unsigned long Tag;
    bool Valid;
};

class cache
{
public:
    virtual ~cache() {};

    // Access the generic cache.
    // You might want to override this in L1D to access the victim cache.
    virtual void addressRequest( unsigned long address);

    // Get Statistics Methods
    virtual UINT64 getTotalMiss();
    virtual UINT64 getHit();
    virtual UINT64 getRequest();
    virtual UINT64 getEntryRemoved();

    // Get Settings Methods
    virtual int getCacheSize();
    virtual int getCacheAssoc();
    virtual int getCacheBlockSize();
    virtual unsigned int getTagSize() {return tagSize;}
    virtual unsigned int getBlockOffsetSize() {return blockOffsetSize;}
    virtual unsigned int getSetSize() {return setSize;}

protected:
    cache( int blockSize, int totalCacheSize, int associativity, cache* nextLevel, bool writebackDirty );

    //Calculate the Tag and Set of an address based on this cache's properties
    unsigned int getTag( unsigned int address );
    unsigned int getSet( unsigned int address );

    // returns -1 for a miss
    // index into array for a hit
    int isHit( unsigned int tagBits, unsigned int setBits );

    // Set a certain index as the Most Receintly Used in its
    // associativity, and adjusts all the appropriate indices to match
    // the LRU scheme
    void updateLRU( int setBits, int MRU_index );

    // Gets the index of the LRU index for a given set of setBits
    int getLRU( int setBits );

    // Gets the index of the MRU index for a given set of setBits
    int getMRU( int setBits );

    // Initializes this cache
    void clearCache();

    void addTotalMiss();
    void addHit();
    void addRequest();
    void addEntryRemoved();

    // Given Properties
    const int blockSz;
    const int totalCacheSz;
    const int assoc;

    // Bit Field Sizes
    const unsigned int blockOffsetSize;
    const unsigned int setSize;
    const unsigned int tagSize;

    const unsigned int tagMask;
    const unsigned int setMask;
    const int maxSetValue;

    // Statistics
    UINT64 totalMisses;
    UINT64 hits;
    UINT64 requests;
    UINT64 entriesKickedOut;

    // The actual cache array
    cacheEntry* cacheMem;

    // The next level in the cache hierachy
    cache* const nextLevel;
    // Does this cache write evicted items to the next level (icaches don't need to)
    const bool writebackDirty;
};

class memory : public cache {
public:
    memory() :
        cache(1, 1, 1, nullptr, false)
    { }

    void addressRequest( unsigned long address ) {
        (void) address;
        addRequest();
    }
};

class victim_cache;

class victim_cache : public cache {
public:
    victim_cache(int blockSize, int totalCacheSize, cache *nextLevel);

    bool access(unsigned long address, unsigned long replacementAddress, bool replacementValid);
    void insert(unsigned long address);

private:
    int firstInvalidEntry();
    unsigned long lineAddress(int entryIndex);
    void removeEntry(int entryIndex);

};

class l1icache : public cache {
public:
    l1icache( int blockSize, int totalCacheSize, int associativity, cache *nextLevel) :
        cache( blockSize, totalCacheSize, associativity, nextLevel, false)
    { }
};

class l1dcache : public cache {
public:
    l1dcache( int blockSize, int totalCacheSize, int associativity, cache *nextLevel, victim_cache *victimLevel) :
        cache( blockSize, totalCacheSize, associativity, nextLevel, true),
        victimLevel(victimLevel)
    { }

    void addressRequest( unsigned long address);

private:
    victim_cache *victimLevel;
};

class l2cache : public cache {
public:
    l2cache(int blockSize, int totalCacheSize, int associativity, cache *nextLevel) :
        cache( blockSize, totalCacheSize, associativity, nextLevel, true)
    { }
};


using namespace std;
/*
This code implements a simple cache simulator. In this implementation, we
assume there is L1 Instruction Cache, L1 Data Cache, and L2 Cache.

We have a base class declared in cache.h file and three derived classes:
L1InstCache, L1DataCache, and L2Cache.

We have a simple memory class to track the number of memory requests.

This is a simplified cache model since we do not differentiate read and write
accesses, which is not true for real cache system.

We only track the number of hits and misses in both L1 and L2 caches.

In both L1 and L2 caches, we use a simple LRU algorithm as cache replacement policy.

*/

/* ===================================================================== */
/* Commandline Switches */
/* ===================================================================== */
KNOB<string> KnobOutputFile(KNOB_MODE_WRITEONCE,    "pintool",
        "outfile", "cache.out", "Cache results file name");

KNOB<string> KnobConfigFile(KNOB_MODE_WRITEONCE,    "pintool",
        "config", "config-base", "Configuration file name");

KNOB<UINT64> KnobInstructionCount(KNOB_MODE_WRITEONCE, "pintool",
        "max_inst","1000000000", "Number of instructions to profile");

// Globals for the various caches
/* ===================================================================== */
l1icache* icache;
l1dcache* dcache;
l2cache* llcache;
memory* mem;
victim_cache* vcache;

// Keep track if instruction counts so we know when to end simmulation
UINT64 icount;

void PrintResults(void);



////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
// TODO: you will need to implement functions which will be called for the victim cache!
victim_cache::victim_cache( int blockSize, int totalCacheSize, cache *nextLevel) :
    cache( blockSize, totalCacheSize, totalCacheSize / blockSize, nextLevel, true)
    { }

int victim_cache::firstInvalidEntry()
{
    for( int i = 0; i < assoc; i++ ) {
        if( cacheMem[i].Valid == false ) {
            return i;
        }
    }
    return -1;
}

unsigned long victim_cache::lineAddress(int entryIndex)
{
    return ((unsigned long) cacheMem[entryIndex].Tag) << getBlockOffsetSize();
}

void victim_cache::removeEntry(int entryIndex)
{
    int removedLRU = cacheMem[entryIndex].LRU_status;

    for( int i = 0; i < assoc; i++ ) {
        if( i == entryIndex ) {
            continue;
        }
        if( cacheMem[i].Valid && cacheMem[i].LRU_status > removedLRU ) {
            cacheMem[i].LRU_status--;
        }
    }

    cacheMem[entryIndex].Valid = false;
    cacheMem[entryIndex].Tag = 0;
    cacheMem[entryIndex].LRU_status = assoc - 1;
}

bool victim_cache::access(unsigned long address, unsigned long replacementAddress, bool replacementValid)
{
    addRequest();

    int hitIndex = isHit( getTag(address), 0 );
    if( hitIndex == -1 ) {
        addTotalMiss();
        return false;
    }

    addHit();

    if( replacementValid ) {
        cacheMem[hitIndex].Tag = getTag(replacementAddress);
        cacheMem[hitIndex].Valid = true;
        updateLRU( 0, hitIndex );
    } else {
        removeEntry( hitIndex );
    }

    return true;
}

void victim_cache::insert(unsigned long address)
{
    int index = firstInvalidEntry();
    if( index == -1 ) {
        index = getLRU( 0 );
    }

    if( cacheMem[index].Valid ) {
        unsigned long evictedAddress = lineAddress( index );
        addEntryRemoved();
        if( nextLevel != nullptr ) {
            nextLevel->addressRequest( evictedAddress );
        }
    }

    cacheMem[index].Tag = getTag( address );
    cacheMem[index].Valid = true;
    updateLRU( 0, index );
}

////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
    


////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
cache::cache( int blockSize, int totalCacheSize, int associativity, cache* nextLevel, bool writebackDirty) :
    // Set Cache properties
    blockSz(blockSize),
    totalCacheSz(totalCacheSize),
    assoc(associativity),
    
    // Calculate Cache bit sizes and masks
    blockOffsetSize(log2(blockSize)),
    setSize(log2(totalCacheSize / (blockSize * associativity))),
    tagSize(ADDRESS_SIZE - blockOffsetSize - setSize),
    tagMask( (1 << tagSize) - 1),
    setMask( (1 << setSize) - 1),
    maxSetValue((int) 1 << setSize),
    // Next level properties
    nextLevel(nextLevel),
    writebackDirty(writebackDirty)
{
    // Allocate memory for the cache array
    cacheMem = new cacheEntry[totalCacheSize/blockSize];

    clearCache();

    // Clear the statistics
    totalMisses = 0;
    hits = 0;
    requests = 0;
    entriesKickedOut = 0;
}

void l1dcache::addressRequest( unsigned long address )
{
    unsigned long tagField = getTag( address );
    unsigned long setField = getSet( address );
    int index = isHit( tagField, setField );

    addRequest();

    if( index != -1 ) {
        addHit();
        updateLRU( setField, index );
        return;
    }

    addTotalMiss();

    int indexLRU = getLRU( setField );
    bool hasVictim = cacheMem[ indexLRU + setField * assoc ].Valid == true;
    unsigned long evictedAddress = 0;

    if( hasVictim ) {
        unsigned long evictedTag = cacheMem[ indexLRU + setField * assoc ].Tag;
        evictedAddress = evictedTag;
        evictedAddress = evictedAddress << ( getSetSize() + getBlockOffsetSize() );
        evictedAddress |= ( (unsigned long) setField << getBlockOffsetSize() );
    }

    bool victimHit = false;
    if( victimLevel != nullptr ) {
        victimHit = victimLevel->access( address, evictedAddress, hasVictim );
    }

    if( !victimHit ) {
        assert( nextLevel != nullptr );
        nextLevel->addressRequest( address );
        if( victimLevel != nullptr && hasVictim ) {
            victimLevel->insert( evictedAddress );
        }
    }

    cacheMem[ indexLRU + setField * assoc ].Tag = tagField;
    cacheMem[ indexLRU + setField * assoc ].Valid = true;
    updateLRU( setField, indexLRU );
}

void cache::clearCache()
{
    // Loop through entire cache array
    for( int i = 0; i < (maxSetValue) * assoc; i++ ) {
        cacheMem[ i ].LRU_status = (i % assoc);
        cacheMem[ i ].Tag = 0;
        cacheMem[ i ].Valid = false;
    }
}

unsigned int cache::getTag( unsigned int address )
{
    unsigned int ret = (address >> (blockOffsetSize + setSize)) & tagMask;
    return ret;
}

unsigned int cache::getSet( unsigned int address )
{
    // Bit Mask to get setBits
    unsigned int ret = (address >> (blockOffsetSize)) & setMask;
    return ret;
}

int cache::isHit( unsigned int tagBits, unsigned int setIndex)
{
    ///cout << "isHit.b" << endl;
    int result = -1;

    // Loop Through By Associativity
    for( int i = 0; i < assoc; i++ )
    {
        // Check if the cache location contains the requested data
        if( cacheMem[ (i + setIndex * assoc) ].Valid == true &&
                cacheMem[ (i + setIndex * assoc) ].Tag == tagBits )
        {
            return i;
            break;
        }
    }

    return result;
}

//
// Update the LRU for the system
// Input:
//  setBits - The set field of the current address
//  MRU_index - The index into the cache's array of the Most Receintly
//     Used Entry (which should be i * setBits for some int i).
// Results:
//  The entry and MRU_index will be 0 to show that it is the MRU.
//  All other entries will be updated to reflect the new MRU.
//
void cache::updateLRU( int setBits, int MRU_index )
{
    int upperBounds = assoc - 1;

    // Update all of the other places necesary to accomidate the change
    for( int i = 0; i < assoc; i++ )
    {
        if( cacheMem[ i + setBits*assoc ].LRU_status >= 0 &&
                cacheMem[ i + setBits*assoc ].LRU_status < upperBounds )
        {
            cacheMem[ i + setBits*assoc ].LRU_status++;
        }
    }

    // Set the new MRU location to show that it is the MRU
    cacheMem[ MRU_index + setBits*assoc ].LRU_status = 0;
}

//
// Input:
//   setBits - The set field of the address
// Output:
//   (int) - The index into the cache of the Least Recently Used
//     value for the given setBits field.
//    -1 If there is an error
//
int cache::getLRU( int setBits )
{
    for( int i = 0; i < assoc; i++ )
    {
        if( cacheMem[ i + setBits*assoc ].LRU_status == (assoc - 1) )
            return i;
    }
    return -1;
}

//
// Input:
//   setBits - The set field of the address
// Output:
//   (int) - The index into the cache of the Most Recently Used
//     value for the given setBits field.
//    -1 If there is an error
//
int cache::getMRU( int setBits )
{
    for( int i = 0; i < assoc; i++ )
    {
        if( cacheMem[ i + setBits*assoc ].LRU_status == 0 )
            return i;
    }
    return -1;
}
//
// Mark that the cache Missed
//
void cache::addTotalMiss()
{
    totalMisses++;
}

//
// Mark that the cache Hit
//
void cache::addHit()
{
    hits++;
}

//
// Mark that a memory request was made
//
void cache::addRequest()
{
    requests++;
}

//
// Mark that an entry was kicked out
//
void cache::addEntryRemoved()
{
    entriesKickedOut++;
}

//
// Get the total Miss Counter
//
UINT64 cache::getTotalMiss()
{
    return totalMisses;
}

//
// Get the Hit Counter
//
UINT64 cache::getHit()
{
    return hits;
}

//
// Get the requests Counter
//
UINT64 cache::getRequest()
{
    return requests;
}

//
// Get the removed entry counter
//
UINT64 cache::getEntryRemoved()
{
    return entriesKickedOut;
}

//
// Get the size of the size of the cache
//
int cache::getCacheSize()
{
    return totalCacheSz;
}

//
// Get the associativity of the cache
//
int cache::getCacheAssoc()
{
    return assoc;
}

//
// Get the block size of the cache
//
int cache::getCacheBlockSize()
{
    return blockSz;
}

//
// Access the cache. Checks for hit/miss and updates appropriate stats.
// On a miss, brings the item in from the next level. If necessary,
// writes the evicted item back to the next level.
// Doesn't distinguish between reads and writes.
//
void cache::addressRequest( unsigned long address ) {

    // Compute Set / Tag
    unsigned long tagField = getTag( address );
    unsigned long setField = getSet( address );

    // Hit or Miss ?
    int index = isHit( tagField, setField );

    // Count that access
    addRequest();

    // Miss
    if( index == -1 ) {
        // Get the LRU index
        int indexLRU = getLRU( setField );
        if( cacheMem[ indexLRU + setField*assoc].Valid == true ) {
            addEntryRemoved();
        }

        // Count that miss
        addTotalMiss();

        assert(nextLevel != nullptr);
        // Write the evicted entry to the next level
        if( writebackDirty &&
            cacheMem[ indexLRU + setField*assoc].Valid == true) {
            int tag = cacheMem[indexLRU + setField*assoc].Tag;
            tag = tag << (getSetSize() + getBlockOffsetSize());
            int Set = setField;
            Set = Set << (getBlockOffsetSize());
            int lru_addr = tag + Set;
            nextLevel->addressRequest(lru_addr);
        }
        // Load the requested address from next level
        nextLevel->addressRequest(address);

        // Update LRU / Tag / Valid
        cacheMem[ indexLRU + setField*assoc].Tag = tagField;
        cacheMem[ indexLRU + setField*assoc].Valid = true;
        updateLRU( setField, indexLRU );
    }
    else {
        // Count that hit
        addHit();

        // Update LRU / Tag / Valid
        updateLRU( setField, index );
    }
}

////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////





////////////////////////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////////////////////////
/* ===================================================================== */
INT32 Usage()
{
    cerr << "This tool represents a cache simulator.\n"
        "\n";

    cerr << KNOB_BASE::StringKnobSummary();

    cerr << endl;

    return -1;
}


/* ===================================================================== */
void CreateCaches(void)
{
    // Check if config file exits
    ifstream config;
    config.open( KnobConfigFile.Value().c_str());
    if(!config.is_open()) {
        cerr << "Cannot open input file : " << KnobConfigFile.Value() << "\n";
        Usage();
        PIN_ExitProcess(EXIT_FAILURE);
    }

    // Create the one and only memory
    mem = new memory();
    vcache = nullptr;

    // Parse config file and create the three caches
    int i = 0;
    while (!config.eof()){
        string line;
        getline(config, line);
        if( line.size() == 0 || line[0] == '#' || (line.size() > 1 && line[0] == '/' && line[1] == '/') ) {
            continue;
        }
        replace( line.begin(), line.end(), ',', ' ' );
        istringstream parser(line);
        int bsize, csize, assoc, vsize;
        switch(i){
            case 0:
                parser >> bsize >> csize >> assoc;
                llcache = new l2cache(bsize, csize, assoc, mem);
                break;
            case 1:
                parser >> bsize >> csize >> assoc;
                icache = new l1icache(bsize, csize, assoc, llcache);
                break;
            case 2:
                vsize = 0;
                parser >> bsize >> csize >> assoc;
                if( !(parser >> vsize) ) {
                    vsize = 0;
                }
                if( vsize > 0 ) {
                    vcache = new victim_cache(bsize, bsize * vsize, llcache);
                }
                dcache = new l1dcache(bsize, csize, assoc, llcache, vcache);
                break;
            default:
                break;
        }
        i++;
    }
}

/* ===================================================================== */
void CheckInstructionLimits(void)
{
    if (KnobInstructionCount.Value() > 0 &&
        icount > KnobInstructionCount.Value()) {
        PrintResults();
        PIN_ExitProcess(EXIT_SUCCESS);
    }
}

/* ===================================================================== */
void MemoryOp(ADDRINT address)
{
    dcache->addressRequest( address );
}

/* ===================================================================== */
void AllInstructions(ADDRINT ins_ptr)
{
    icount++;
    icache->addressRequest( ins_ptr );

    CheckInstructionLimits();
}

/* ===================================================================== */
void PrintResults(void)
{
    ofstream out(KnobOutputFile.Value().c_str());

    out.setf(ios::fixed, ios::floatfield);
    out.precision(2);

    out << "---------------------------------------";
    out << endl << "\t\tSimulation Results" << endl;
    out << "---------------------------------------";

    out << endl
        << "Memory system->" << endl
        << "\t\tDcache size (bytes)         : " << dcache->getCacheSize() << endl
        << "\t\tDcache ways                 : " << dcache->getCacheAssoc() << endl
        << "\t\tDcache block size (bytes)   : " << dcache->getCacheBlockSize() << endl;

    if( vcache != nullptr ) {
        out << "\t\tVictim cache entries        : " << vcache->getCacheAssoc() << endl;
    }

    out << endl
        << "\t\tIcache size (bytes)         : " << icache->getCacheSize() << endl
        << "\t\tIcache ways                 : " << icache->getCacheAssoc() << endl
        << "\t\tIcache block size (bytes)   : " << icache->getCacheBlockSize() << endl;

    out << endl
        << "\t\tL2-cache size (bytes)       : " << llcache->getCacheSize() << endl
        << "\t\tL2-cache ways               : " << llcache->getCacheAssoc() << endl
        << "\t\tL2-cache block size (bytes) : " << llcache->getCacheBlockSize() << endl;

    out << "Simulated events->" << endl;

    out << "\t\t I-Cache Miss: " << icache->getTotalMiss() << " out of " << icache->getRequest() << endl;

    out << "\t\t D-Cache Miss: " << dcache->getTotalMiss() << " out of " << dcache->getRequest() << endl;

    if( vcache != nullptr ) {
        out << "\t\t Victim-Cache Hits: " << vcache->getHit() << " out of " << vcache->getRequest() << endl;
    }

    out << "\t\t L2-Cache Miss: " << llcache->getTotalMiss() << " out of " << llcache->getRequest() << endl;

    out << endl;

    out << "\t\t Requests resulted in " << icache->getRequest() + dcache->getRequest() << " L1 requests, "
        << llcache->getRequest() << " L2 requests, "
        << (*mem).getRequest() << " mem requests " << endl;

    out << endl;

    out << endl;
    out << "------------------------------------------------";
    out << endl;
}

/// Add instruction instrumentation calls
/* ===================================================================== */
void Instruction(INS ins, VOID *v)
{
    // All instructions access the icache
    INS_InsertCall(ins, IPOINT_BEFORE, (AFUNPTR) AllInstructions,
            IARG_INST_PTR, IARG_END);

    // Reads go to dcache
    if (INS_IsMemoryRead(ins)) {
        INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE, (AFUNPTR) MemoryOp,
                IARG_MEMORYREAD_EA,
                IARG_END);

    }

    // Writes go to dcache
    // XXX: note this is not an else branch. It's pretty typical for an x86
    // instruction to be both a read and a write.
    if ( INS_IsMemoryWrite(ins) ) {
        INS_InsertPredicatedCall(
                ins, IPOINT_BEFORE,  (AFUNPTR) MemoryOp,
                IARG_MEMORYWRITE_EA,
                IARG_END);
    }
}

/* ===================================================================== */
void Fini(int n, VOID *v)
{
    PrintResults();
}

/* ===================================================================== */
int main(int argc, char *argv[])
{
    if( PIN_Init(argc,argv) ){
        return Usage();
    }

    CreateCaches();

    INS_AddInstrumentFunction(Instruction, 0);

    PIN_AddFiniFunction(Fini, 0);

    PIN_StartProgram();

    return 0;
}
