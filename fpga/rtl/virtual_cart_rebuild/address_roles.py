import re

PORT = '        AddrRoles : out std_logic_vector(5 downto 0);\n'

def add_port(source):
    source, n = re.subn(r'(?m)^(\s*A\s*:\s*(?:out|buffer)\s+std_logic_vector\(15 downto 0\);)',
                        lambda m: PORT+m[1],source,count=1)
    assert n==1
    return source

def transform(relative, source):
    original=source
    if relative.endswith('/T80_Pack.vhd'):
        return add_port(source)
    if relative.endswith('/GBse.vhd'):
        source=add_port(source)
        source=source.replace(PORT,PORT+'        READ_CYCLE : out std_logic;\n')
        source=source.replace('    WRITE_CYCLE               <= Write;',
            '    READ_CYCLE <= IntCycle_n when MCycle = "001" else\n'+
            '                  \'0\' when MCycle = "011" and IntCycle_n = \'0\' else\n'+
            '                  not NoRead and not Write;\n    WRITE_CYCLE               <= Write;',1)
        source,n=re.subn(r'(?m)^(\s*A\s*=>\s*A,)',r'            AddrRoles => AddrRoles,\n\1',source)
        assert n==1
        return source
    if not relative.endswith('/T80.vhd'):
        return source
    source=add_port(source)
    source,n=re.subn(r'(?m)^(\s*A\s*<= SS_1\(31 downto 16\);[^\n]*)',
                     r'                AddrRoles <= "000001";\n\1',source)
    assert n==1
    anchor='if Mode < 2 then\n'
    assert source.count(anchor)==1
    source=source.replace(anchor,anchor+'                        AddrRoles <= "000010";\n')
    begin=source.index("if T_Res = '1' then\n")
    end=source.index('Save_ALU_r <= Save_ALU;',begin)
    part=source[begin:end]
    part=part.replace("if T_Res = '1' then\n", "if T_Res = '1' then\n"+
                      '                    -- PC=0, DATA=1, BC=2, DE=3, HL=4, SP=5.\n'+
                      '                    AddrRoles <= "000001";\n',1)
    anchor="elsif JumpXY = '1' then\n"
    assert part.count(anchor)==1
    part=part.replace(anchor,anchor+'                        AddrRoles <= "010001";\n')
    for selector,bits in [('aSP','100000'),('aBC','000100'),('aDE','001000'),('aZI','000010'),('aIOA','000010')]:
        anchor='when '+selector+' =>\n';assert part.count(anchor)==1
        part=part.replace(anchor,anchor+f'                            AddrRoles <= "{bits}";\n')
    anchor='when aXY =>\n';assert part.count(anchor)==1
    part=part.replace(anchor,anchor+'                            AddrRoles <= "010000";\n')
    anchor="if NextIs_XY_Fetch = '1' then\n";assert part.count(anchor)==1
    part=part.replace(anchor,anchor+'                                    AddrRoles <= "000001";\n')
    anchor='A <= TmpAddr;'
    at=part.index(anchor,part.index('when aXY =>'))
    part=part[:at]+'AddrRoles <= "000010";\n                                    '+part[at:]
    source=source[:begin]+part+source[end:]
    stripped=re.sub(r'AddrRoles\s*:\s*out std_logic_vector\(5 downto 0\);','',source)
    stripped=re.sub(r'AddrRoles\s*<=\s*"[01]{6}";','',stripped)
    def tokens(text):
        return re.sub(r'\s+','',re.sub(r'--[^\n]*','',text))
    assert tokens(stripped)==tokens(original), 'A native behavioral token changed'
    return source
