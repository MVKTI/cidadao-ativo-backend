-- =====================================================
-- BACKEND CIDADÃO ATIVO - ESTRUTURA COMPLETA SUPABASE
-- =====================================================

-- 1. CONFIGURAÇÃO INICIAL
-- Primeiro, vamos criar as extensões necessárias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- =====================================================
-- 2. TABELAS PRINCIPAIS
-- =====================================================

-- Tabela de perfis de usuário (extende auth.users)
CREATE TABLE public.usuarios (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    nome VARCHAR(100) NOT NULL,
    telefone VARCHAR(15),
    cidade VARCHAR(100) NOT NULL,
    estado VARCHAR(2) NOT NULL,
    cep VARCHAR(10),
    endereco TEXT,
    avatar_url TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabela de prefeituras
CREATE TABLE public.prefeituras (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    nome VARCHAR(100) NOT NULL,
    cidade VARCHAR(100) NOT NULL,
    estado VARCHAR(2) NOT NULL,
    cnpj VARCHAR(18),
    email VARCHAR(100),
    telefone VARCHAR(15),
    endereco TEXT,
    responsavel VARCHAR(100),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Índices para busca eficiente
    CONSTRAINT unique_prefeitura_cidade UNIQUE(cidade, estado)
);

-- Tabela de categorias de problemas
CREATE TABLE public.categorias (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    nome VARCHAR(50) NOT NULL UNIQUE,
    descricao TEXT,
    icone VARCHAR(50), -- Nome do ícone (ex: 'road-repair', 'light-bulb')
    cor VARCHAR(7) DEFAULT '#6366f1', -- Cor em hexadecimal
    is_active BOOLEAN DEFAULT true,
    ordem INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabela principal de ocorrências
CREATE TABLE public.ocorrencias (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    protocolo VARCHAR(20) UNIQUE NOT NULL,
    
    -- Relacionamentos
    user_id UUID REFERENCES usuarios(id) ON DELETE SET NULL,
    prefeitura_id UUID REFERENCES prefeituras(id),
    categoria_id UUID REFERENCES categorias(id),
    
    -- Dados da ocorrência
    titulo VARCHAR(100) NOT NULL,
    descricao TEXT NOT NULL,
    
    -- Localização (usando PostGIS para consultas geoespaciais)
    latitude DECIMAL(10,8) NOT NULL,
    longitude DECIMAL(11,8) NOT NULL,
    endereco TEXT NOT NULL,
    bairro VARCHAR(100),
    referencia TEXT, -- Ponto de referência
    
    -- Mídia
    fotos TEXT[] DEFAULT '{}', -- Array de URLs das fotos
    videos TEXT[] DEFAULT '{}', -- Array de URLs dos vídeos
    
    -- Status e controle
    status VARCHAR(20) DEFAULT 'recebido' CHECK (status IN ('recebido', 'em_analise', 'em_atendimento', 'resolvido', 'rejeitado')),
    prioridade VARCHAR(10) DEFAULT 'normal' CHECK (prioridade IN ('baixa', 'normal', 'alta', 'urgente')),
    
    -- Metadados
    ip_origem INET,
    user_agent TEXT,
    
    -- Timestamps
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    resolved_at TIMESTAMP WITH TIME ZONE
);

-- Tabela de logs de mudança de status
CREATE TABLE public.status_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ocorrencia_id UUID REFERENCES ocorrencias(id) ON DELETE CASCADE,
    status_anterior VARCHAR(20),
    status_novo VARCHAR(20) NOT NULL,
    observacao TEXT,
    anexos TEXT[], -- URLs de anexos relacionados à atualização
    
    -- Quem fez a alteração
    updated_by UUID REFERENCES usuarios(id),
    updated_by_admin BOOLEAN DEFAULT false,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabela de comentários/mensagens
CREATE TABLE public.comentarios (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ocorrencia_id UUID REFERENCES ocorrencias(id) ON DELETE CASCADE,
    user_id UUID REFERENCES usuarios(id),
    
    conteudo TEXT NOT NULL,
    is_internal BOOLEAN DEFAULT false, -- Comentário interno (só admin vê)
    anexos TEXT[] DEFAULT '{}',
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Tabela de administradores por prefeitura
CREATE TABLE public.admin_prefeituras (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES usuarios(id) ON DELETE CASCADE,
    prefeitura_id UUID REFERENCES prefeituras(id) ON DELETE CASCADE,
    
    role VARCHAR(20) DEFAULT 'admin' CHECK (role IN ('admin', 'moderador', 'operador')),
    permissions TEXT[] DEFAULT '{}', -- Array de permissões específicas
    
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT unique_user_prefeitura UNIQUE(user_id, prefeitura_id)
);

-- =====================================================
-- 3. ÍNDICES PARA PERFORMANCE
-- =====================================================

-- Índices para ocorrências (consultas mais frequentes)
CREATE INDEX idx_ocorrencias_user_id ON ocorrencias(user_id);
CREATE INDEX idx_ocorrencias_prefeitura_id ON ocorrencias(prefeitura_id);
CREATE INDEX idx_ocorrencias_status ON ocorrencias(status);
CREATE INDEX idx_ocorrencias_created_at ON ocorrencias(created_at DESC);
CREATE INDEX idx_ocorrencias_location ON ocorrencias(latitude, longitude);

-- Índice composto para consultas de dashboard
CREATE INDEX idx_ocorrencias_dashboard ON ocorrencias(prefeitura_id, status, created_at DESC);

-- Índices para logs
CREATE INDEX idx_status_logs_ocorrencia ON status_logs(ocorrencia_id, created_at DESC);
CREATE INDEX idx_comentarios_ocorrencia ON comentarios(ocorrencia_id, created_at);

-- =====================================================
-- 4. FUNÇÕES AUXILIARES
-- =====================================================

-- Função para gerar protocolo único
CREATE OR REPLACE FUNCTION generate_protocolo()
RETURNS TEXT AS $$
DECLARE
    new_protocolo TEXT;
    protocolo_exists BOOLEAN;
BEGIN
    LOOP
        -- Gera protocolo: ANO + 6 dígitos aleatórios
        new_protocolo := EXTRACT(YEAR FROM NOW())::TEXT || 
                        LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
        
        -- Verifica se já existe
        SELECT EXISTS(SELECT 1 FROM ocorrencias WHERE protocolo = new_protocolo) 
        INTO protocolo_exists;
        
        -- Se não existe, retorna
        IF NOT protocolo_exists THEN
            RETURN new_protocolo;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Função para atualizar updated_at automaticamente
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 5. TRIGGERS
-- =====================================================

-- Trigger para gerar protocolo automaticamente
CREATE OR REPLACE FUNCTION set_protocolo()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.protocolo IS NULL OR NEW.protocolo = '' THEN
        NEW.protocolo := generate_protocolo();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_protocolo
    BEFORE INSERT ON ocorrencias
    FOR EACH ROW
    EXECUTE FUNCTION set_protocolo();

-- Triggers para updated_at
CREATE TRIGGER trigger_usuarios_updated_at
    BEFORE UPDATE ON usuarios
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_ocorrencias_updated_at
    BEFORE UPDATE ON ocorrencias
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Trigger para log de mudança de status
CREATE OR REPLACE FUNCTION log_status_change()
RETURNS TRIGGER AS $$
BEGIN
    -- Só loga se o status realmente mudou
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO status_logs (ocorrencia_id, status_anterior, status_novo)
        VALUES (NEW.id, OLD.status, NEW.status);
        
        -- Atualiza resolved_at se status foi para 'resolvido'
        IF NEW.status = 'resolvido' AND OLD.status != 'resolvido' THEN
            NEW.resolved_at = NOW();
        ELSIF NEW.status != 'resolvido' THEN
            NEW.resolved_at = NULL;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_log_status_change
    BEFORE UPDATE ON ocorrencias
    FOR EACH ROW
    EXECUTE FUNCTION log_status_change();

-- =====================================================
-- 6. RLS (ROW LEVEL SECURITY)
-- =====================================================

-- Habilita RLS nas tabelas principais
ALTER TABLE usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE ocorrencias ENABLE ROW LEVEL SECURITY;
ALTER TABLE comentarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE status_logs ENABLE ROW LEVEL SECURITY;

-- Políticas para usuários - podem ver/editar apenas seus próprios dados
CREATE POLICY "Usuários podem ver próprio perfil" ON usuarios
    FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Usuários podem atualizar próprio perfil" ON usuarios
    FOR UPDATE USING (auth.uid() = id);

-- Políticas para ocorrências - usuários veem suas próprias + admins veem da prefeitura
CREATE POLICY "Usuários podem ver próprias ocorrências" ON ocorrencias
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Usuários podem criar ocorrências" ON ocorrencias
    FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Admins podem ver ocorrências da prefeitura" ON ocorrencias
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM admin_prefeituras ap
            WHERE ap.user_id = auth.uid() 
            AND ap.prefeitura_id = ocorrencias.prefeitura_id
            AND ap.is_active = true
        )
    );

CREATE POLICY "Admins podem atualizar ocorrências da prefeitura" ON ocorrencias
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM admin_prefeituras ap
            WHERE ap.user_id = auth.uid() 
            AND ap.prefeitura_id = ocorrencias.prefeitura_id
            AND ap.is_active = true
        )
    );

-- =====================================================
-- 7. DADOS INICIAIS
-- =====================================================

-- Inserir categorias padrão
INSERT INTO categorias (nome, descricao, icone, cor, ordem) VALUES
('Buracos na via', 'Problemas relacionados a buracos e pavimentação', 'road-repair', '#ef4444', 1),
('Iluminação pública', 'Lâmpadas queimadas, postes danificados', 'light-bulb', '#f59e0b', 2),
('Lixo e limpeza', 'Acúmulo de lixo, falta de coleta', 'trash', '#10b981', 3),
('Vandalismo', 'Pichações, danos ao patrimônio público', 'alert-triangle', '#8b5cf6', 4),
('Sinalização', 'Placas danificadas, falta de sinalização', 'sign', '#06b6d4', 5),
('Áreas verdes', 'Poda de árvores, manutenção de praças', 'tree-deciduous', '#84cc16', 6),
('Calçadas', 'Calçadas danificadas, acessibilidade', 'footprints', '#6b7280', 7),
('Outros', 'Outras solicitações não categorizadas', 'help-circle', '#64748b', 8);

-- Exemplo de prefeitura (adaptar conforme necessário)
INSERT INTO prefeituras (nome, cidade, estado, email, telefone) VALUES
('Prefeitura Municipal de Jaú', 'Jaú', 'SP', 'ouvidoria@jau.sp.gov.br', '(14) 3602-1234');

-- =====================================================
-- 8. VIEWS ÚTEIS PARA RELATÓRIOS
-- =====================================================

-- View com dados completos da ocorrência
CREATE VIEW v_ocorrencias_completas AS
SELECT 
    o.id,
    o.protocolo,
    o.titulo,
    o.descricao,
    o.status,
    o.prioridade,
    o.endereco,
    o.latitude,
    o.longitude,
    o.created_at,
    o.updated_at,
    o.resolved_at,
    
    -- Dados do usuário
    u.nome as usuario_nome,
    u.telefone as usuario_telefone,
    au.email as usuario_email,
    
    -- Dados da categoria
    c.nome as categoria_nome,
    c.icone as categoria_icone,
    c.cor as categoria_cor,
    
    -- Dados da prefeitura
    p.nome as prefeitura_nome,
    p.cidade,
    p.estado,
    
    -- Tempo de resolução
    CASE 
        WHEN o.resolved_at IS NOT NULL THEN 
            EXTRACT(EPOCH FROM (o.resolved_at - o.created_at))/3600
        ELSE NULL 
    END as horas_para_resolucao,
    
    -- Contadores
    array_length(o.fotos, 1) as total_fotos,
    array_length(o.videos, 1) as total_videos
    
FROM ocorrencias o
LEFT JOIN usuarios u ON o.user_id = u.id
LEFT JOIN auth.users au ON u.id = au.id
LEFT JOIN categorias c ON o.categoria_id = c.id
LEFT JOIN prefeituras p ON o.prefeitura_id = p.id;

-- View para dashboard - estatísticas por prefeitura
CREATE VIEW v_dashboard_stats AS
SELECT 
    p.id as prefeitura_id,
    p.nome as prefeitura_nome,
    COUNT(o.id) as total_ocorrencias,
    COUNT(CASE WHEN o.status = 'recebido' THEN 1 END) as recebidas,
    COUNT(CASE WHEN o.status = 'em_analise' THEN 1 END) as em_analise,
    COUNT(CASE WHEN o.status = 'em_atendimento' THEN 1 END) as em_atendimento,
    COUNT(CASE WHEN o.status = 'resolvido' THEN 1 END) as resolvidas,
    COUNT(CASE WHEN o.status = 'rejeitado' THEN 1 END) as rejeitadas,
    
    -- Percentual de resolução
    ROUND(
        (COUNT(CASE WHEN o.status = 'resolvido' THEN 1 END) * 100.0 / NULLIF(COUNT(o.id), 0)), 
        2
    ) as percentual_resolucao,
    
    -- Tempo médio de resolução (em horas)
    ROUND(
        AVG(CASE 
            WHEN o.resolved_at IS NOT NULL THEN 
                EXTRACT(EPOCH FROM (o.resolved_at - o.created_at))/3600
        END), 
        2
    ) as tempo_medio_resolucao_horas
    
FROM prefeituras p
LEFT JOIN ocorrencias o ON p.id = o.prefeitura_id
WHERE o.created_at >= CURRENT_DATE - INTERVAL '30 days' -- Últimos 30 dias
GROUP BY p.id, p.nome;

-- =====================================================
-- 9. COMENTÁRIOS E DOCUMENTAÇÃO
-- =====================================================

COMMENT ON TABLE usuarios IS 'Perfis dos usuários do sistema, estende auth.users do Supabase';
COMMENT ON TABLE prefeituras IS 'Cadastro das prefeituras que utilizam o sistema';
COMMENT ON TABLE categorias IS 'Categorias de problemas urbanos que podem ser reportados';
COMMENT ON TABLE ocorrencias IS 'Tabela principal com todas as solicitações dos cidadãos';
COMMENT ON TABLE status_logs IS 'Log de todas as mudanças de status das ocorrências';
COMMENT ON TABLE comentarios IS 'Comentários e mensagens relacionadas às ocorrências';
COMMENT ON TABLE admin_prefeituras IS 'Relaciona usuários que são administradores de prefeituras';

COMMENT ON COLUMN ocorrencias.protocolo IS 'Número único de protocolo gerado automaticamente';
COMMENT ON COLUMN ocorrencias.fotos IS 'Array de URLs das fotos armazenadas no Supabase Storage';
COMMENT ON COLUMN ocorrencias.videos IS 'Array de URLs dos vídeos armazenados no Supabase Storage';