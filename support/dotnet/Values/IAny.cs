using Runtime = org.mbarbon.p.runtime.Runtime;
using Opcode = org.mbarbon.p.runtime.Opcode;
using RxResult = org.mbarbon.p.runtime.RxResult;
using System.Collections.Generic;

namespace org.mbarbon.p.values
{
    public interface IP5Value
    {
    }

    public interface IP5Referrable : IP5Value
    {
        void Bless(Runtime runtime, P5SymbolTable stash);
        bool IsBlessed(Runtime runtime);
        P5SymbolTable Blessed(Runtime runtime);
        string ReferenceTypeString(Runtime runtime);
    }

    public interface IP5Any : IP5Referrable
    {
        P5Scalar AsScalar(Runtime runtime);
        string AsString(Runtime runtime);
        int AsInteger(Runtime runtime);
        double AsFloat(Runtime runtime);
        bool AsBoolean(Runtime runtime);
        int StringLength(Runtime runtime);

        int GetPos(Runtime runtime);
        int GetPos(Runtime runtime, out bool _pos_set);

        IP5Any AssignIterator(Runtime runtime, IEnumerator<IP5Any> e);
        void Undef(Runtime runtime);

        IP5Any Clone(Runtime runtime, int depth);
        IP5Any Localize(Runtime runtime);

        P5Scalar DereferenceScalar(Runtime runtime);
        IP5Array DereferenceArray(Runtime runtime);
        P5Hash DereferenceHash(Runtime runtime);
        P5Typeglob DereferenceGlob(Runtime runtime);
        P5Code DereferenceSubroutine(Runtime runtime);
        P5Handle DereferenceHandle(Runtime runtime);

        P5Scalar VivifyScalar(Runtime runtime);
        IP5Array VivifyArray(Runtime runtime);
        P5Hash VivifyHash(Runtime runtime);

        P5Code FindMethod(Runtime runtime, string method);
    }

    public interface IP5Enumerable : IP5Value
    {
        IEnumerator<IP5Any> GetEnumerator(Runtime runtime);
    }

    public interface IP5Regex : IP5Referrable
    {
        IP5Any Match(Runtime runtime, IP5Any value, int flags,
                     Opcode.ContextValues cxt, ref RxResult oldState);
        IP5Any MatchGlobal(Runtime runtime, IP5Any value, int flags,
                           Opcode.ContextValues cxt, ref RxResult oldState);
        bool MatchString(Runtime runtime, string str, int pos, bool allow_zero,
                         ref RxResult oldState);
        string GetOriginal();
    }
}
